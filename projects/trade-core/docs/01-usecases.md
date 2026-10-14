# 01 · 核心用例

> 阶段 0 · D1 产出物（v2，含退货退款链路）
>
> 本文档只回答「系统里到底发生什么」，不回答「怎么实现」。实现细节（表结构、SQL、中间件）留给 D3/D4 与阶段 3。
> **本文档是 D2 状态机、D3 API 契约、D4 表字段草案的共同上游** —— 这里含糊，后面全部返工。
>
> 本文档共定义 **6 个用例**、**7 条全局不变量（INV-1…INV-7）**、**16 个端点**。

## 0. 全局语义决策

| # | 决策 | 取值 | 影响 |
| --- | --- | --- | --- |
| A | 库存扣减时机 | **下单时预占**（`available -= n`，`reserved += n`） | DoD #1 只有下单即扣才有意义 |
| B | 预占失败 | 返回 `STOCK_INSUFFICIENT`，**不创建订单** | 维持「成功订单数 = 预占成功数」 |
| C | 支付方回调可达结果 | `PAY_SUCCESS` / `PAY_FAILED` / `REFUND_SUCCESS` | 必须有与当前状态矛盾的回调才能测 DoD #3 乱序场景 |
| D | 超时取消触发 | 延迟队列 + **到期扫描兜底** | DoD #4 要求重启不丢任务 |
| E | 库存归还时机 | **与状态流转同一事务**；且触发点是「**货回到仓库**」，不是「退款回调」 | 货在途时归还库存 = 制造「显示有货、实际发不出」的新式超卖 |
| F | 订单与商品的关系 | 订单 + 订单项两表（支持多商品） | W4 先跑通单商品路径 |
| G | 身份 | 下单必须有 `user_id` | 鉴权 W5 完善，D1 假定上层传入可信 `user_id` |
| H | 发货与签收 | 不接物流方回调。支付成功后自动发货（延迟可配，演示默认 5 min），发货后自动签收（默认 3 天），时间由**调度器定时任务**推进 | 全程可控、可测、可手动拨表，不需要外部依赖 |
| I | 退款粒度 | 数据模型按**订单项**粒度设计（`order_items.refund_status`），v1 校验层强制「必须退全部项」 | 以后支持部分退货只需删掉一条校验，不改表、不改状态机 |
| J | 手动操作 | 保留 5 个手动端点：下单、取消订单、申请退款、手动发货、手动签收 | 日常开发不依赖调度器时序，也便于演示与压测 |

### 库存模型（四栏）

| 字段 | 含义 | 什么时候停在这里 |
| --- | --- | --- |
| `available` | 在仓库，可售 | 空闲库存；退货验货合格后也回到这里（**「已签收但未售出」的货就在 available**） |
| `reserved` | 已售未发（钱到手，货没动） | 待支付 / 已支付未发货 |
| `in_transit` | 已发货、未签收 | 正向在途、在驿站；**退货包裹在途中也算 in_transit**（方向不影响定义） |
| `damaged` | 验货不合格，不可售未销毁 | 退货验货不合格 |

> **为什么不加「已签收」字段**：「已签收」不是库存状态，而是一次转移的终点 —— 签收瞬间货就从 `in_transit` 移出，落到 `available` 或 `damaged`，没有中间停留的需要。加这个字段会让它和 `in_transit` 争抢「货在哪」的解释权。签收这个**事实**记在订单项上（`order_items.delivered_at` / `received_at`），属于订单域。

### 全局不变量（Invariants · 共 7 条）

| ID | 不变量 | 对应 |
| --- | --- | --- |
| INV-1 | `available` / `reserved` / `in_transit` / `damaged` **四栏均 `>= 0`** | DoD #1 |
| INV-2 | `available + reserved + in_transit + damaged` = **我方在库/在途**总量。货经正向签收交付用户后即离开这个恒等式，转入「已售出」，不再计入四栏 | 对账 |
| INV-3 | 同一 `Idempotency-Key` 只对应一笔订单 | DoD #2 |
| INV-4 | 同一 `payment_event` 只被消费一次 | DoD #3 |
| INV-5 | 订单状态只能沿状态机合法边转移，且**每个事件只生效一次** | DoD #3 |
| INV-6 | 终态（`COMPLETED` / `CANCELLED` / `REFUNDED`）不可再变 | DoD #3 #4 |
| INV-7 | 状态与库存不脱节：订单处于终态（`COMPLETED` / `CANCELLED`）时，不存在属于它的 `reserved` 或 `in_transit` 残留。**例外**：`REFUNDED` 允许仍有 `in_transit`（退货在途），这是唯一的「终态 + 仍有在途货」的组合 | 对账 |

### 路由约定（全文以此为准）

| 规则 | 取值 |
| --- | --- |
| HTTP 方法 | **只用 `GET` 与 `POST`**，不用 PUT / PATCH / DELETE（查询用 `GET`，一切写操作与动作都用 `POST`） |
| 动作型路径 | **动词在前、ID 在后**：`/{资源}/{动词}/{id}`。动作与资源列表不混淆，也不会与 `GET /orders/{id}` 撞车 |
| 资源型路径 | 集合 `GET /orders`、单体 `GET /orders/{id}` |
| 路径分段 | 全小写 + 中划线（`return-received`），无版本前缀（v1 由部署环境承担） |

**最终端点清单（16 个，作为 D3 的输入）**

| # | 方法与路径 | 归属 | 说明 |
| --- | --- | --- | --- |
| 1 | `POST /orders` | 用户 | 下单（幂等键在请求头） |
| 2 | `GET /orders` | 用户 | 我的订单列表 |
| 3 | `GET /orders/{id}` | 用户 | 订单详情 |
| 4 | `POST /orders/cancel/{id}` | 用户 | 取消未支付订单 |
| 5 | `POST /orders/refund/{id}` | 用户 | 申请退款（v1 整单退） |
| 6 | `POST /orders/refund-revoke/{id}` | 用户 | 撤销退款申请（仅钱未退、货未到仓） |
| 7 | `GET /products` | 商品 | 商品列表 |
| 8 | `GET /products/{id}` | 商品 | 商品详情 |
| 9 | `POST /payments/pay/{order_id}` | 支付 | 发起支付，返回支付方所需参数 |
| 10 | `POST /payments/callback/{provider}` | 支付 | 支付方回调（验签 + 幂等） |
| 11 | `POST /payments/mock-success/{order_id}` | 支付 | 开发环境模拟支付成功（可砍） |
| 12 | `POST /admin/orders/ship/{id}` | 管理 | 手动发货 |
| 13 | `POST /admin/orders/deliver/{id}` | 管理 | 手动签收 |
| 14 | `POST /admin/orders/return-received/{id}` | 管理 | 手动确认退货包裹入库 |
| 15 | `GET /admin/orders` | 管理 | 按状态筛选订单，`REFUNDING` 队列靠它 |
| 16 | `GET /healthz` | 运维 | 存活探测（D6 实现） |

### 术语

- **预占（reserve）**：`available → reserved`，货款已在途/已到账，货未发出。
- **发货（ship）**：`reserved → in_transit`。
- **签收（receive）**：货回到仓库/到用户手上并确认收货，`in_transit` 移出。
  - 正向签收（用户收到货）：`in_transit` 移出后货归用户，不再计入我们的库存。
  - 逆向签收（退货回到仓库）：`in_transit → available`（合格）或 `→ damaged`（不合格）。
- **归还（release）**：`reserved → available`，只用于「未发货即取消/退款」。
- **支付事件（payment event）**：支付方发来的一次通知，有自己的唯一 `event_id` 与签名。
- **调度器（scheduler）**：进程内定时任务，负责推进超时取消、自动发货、自动签收。多实例部署时必须靠条件更新保证幂等。

---

## 用例 1 · 下单（Create Order）

**目标**：用户提交购买请求，系统原子地预占库存并创建一笔待支付订单。

**触发者**：已登录用户，经由前端调用 `POST /orders`（HTTP）。

**前置条件**：`user_id` 有效；请求带 `Idempotency-Key`；`items: [{product_id, quantity}]` 每项 `quantity >= 1`；商品存在且 `ON_SALE`；库存充足。

**主流程**

1. 客户端生成 `Idempotency-Key`（UUID），随请求发出。
2. 服务端在幂等表中占位该 key，状态 `IN_PROGRESS`，绑定 `user_id` + 请求指纹。
3. 校验：`user_id` 有效、请求体合法、商品存在且 `ON_SALE`。
4. 计算 `total_amount = Σ(服务端价格 × quantity)`（**不信客户端传的价格**）。
5. 逐商品项**原子预占**：`available >= n` 时 `available -= n`、`reserved += n`。
6. 全部预占成功后写 `orders`（`PENDING_PAYMENT`，`expires_at = now + 30min`）+ `order_items`（`refund_status = NONE`）。
7. 写 `order_status:{order_id}` 缓存；把 `order_id` 加入延迟队列，`score = expires_at`。
8. 幂等表置 `COMPLETED`，绑定 `order_id` 与响应快照。
9. 返回 `201 Created`：`{ order_id, status, total_amount, expires_at }`。

> **第 5–6 步必须同一事务**，且先占库存再写订单 —— 反过来会先产生订单再发现没库存，中间态暴露更久。

**异常 / 分支流程**

| 分支 | 条件 | 处理 |
| --- | --- | --- |
| B1 幂等命中 | 同 key + 同请求指纹 | 不重复下单，回放首次响应（含原 `order_id`），200 |
| B2 幂等冲突 | 同 key + 不同指纹 | `409 IDEMPOTENCY_KEY_REUSED`，不创建订单 |
| B3 处理中 | 同 key，前次未完成 | `409 IDEMPOTENCY_IN_PROGRESS` |
| B4 库存不足 | `available < n` | 事务回滚（其他项一并回滚），`409 STOCK_INSUFFICIENT`，不创建订单 |
| B5 商品异常 | 不存在 / 已下架 | `404 PRODUCT_NOT_FOUND` / `409 PRODUCT_OFF_SALE` |
| B6 参数非法 | `quantity <= 0`、items 空、超上限 | `400 VALIDATION_ERROR` |
| B7 并发争抢 | 1000 请求抢 100 库存 | 恰好 100 个第 5 步成功，其余走 B4；INV-1、INV-2 必须成立（DoD #1） |

**数据变化**：`orders` +1（`PENDING_PAYMENT`）；`order_items` +N；`stock` 各项 `available -= n, reserved += n`；`idempotency_keys` +1；Redis 缓存 + 延迟队列。**不写** `payments`。

---

## 用例 2 · 支付回调 → 自动发货（Payment Callback）

**目标**：支付方把支付结果通知给系统，系统幂等、乱序无关地推进订单状态；支付成功后按配置自动进入发货流程。

**触发者**：第三方支付方（`POST /payments/callback/{provider}`）。开发环境可用 `POST /payments/mock-success` 手动触发同一条链路。

**前置条件**：请求体含 `event_id`、`provider`、`order_id`、`result`、`amount`、`signature`、`occurred_at`；订单存在（可能是 `PENDING_PAYMENT`，也可能已是终态 —— 都要能正确处理）。

**主流程**（顺序即实现顺序）

1. 支付方发起通知（可能重复、乱序、延迟）。
2. **验签**：失败 → 4xx，**不落任何业务数据**（只记安全日志）。
3. **事件去重**：`INSERT ... ON CONFLICT DO NOTHING` 写 `payment_events(event_id)`。冲突（已处理过）→ 返回 200，**状态零流转**（DoD #3 核心）。
4. 读订单当前状态与 `total_amount`。
5. **合法性 + 金额校验**：金额不符 → 落 `AMOUNT_MISMATCH`，不流转，告警；目标状态与当前矛盾 → 落 `IGNORED`，不流转。
6. **一个事务**内：`UPDATE orders SET status='PAID', paid_at=now() WHERE id=? AND status='PENDING_PAYMENT'`（影响行数须为 1）；写 `payments`；`payment_events` 置 `PROCESSED`。
7. 提交后：更新 `order_status:{order_id}`；**从延迟队列移除该订单**（防止已支付订单被超时取消）。
8. 返回 200 + 支付方要求的响应体（如 `{"code":"SUCCESS"}`）。**必须同步提交事务后才返回** —— 先返回再异步处理，进程崩溃会丢回调且支付方不再重推。

**发货推进（两条路径，行为必须完全一致）**

- 路径 A（自动）：第 7 步之后，若配置 `AUTO_SHIP_DELAY = 0` 则立即发货，否则把订单加入延迟队列，`score = now + AUTO_SHIP_DELAY`（**演示默认 5 min**，可用环境变量改成 0）。
- 路径 B（手动）：`POST /admin/orders/ship/{id}`（见用例 4）。
- 发货动作 = 条件更新 `WHERE id=? AND status='PAID'` → `status='SHIPPED'`、`shipped_at=now()`、`expected_delivered_at = now + AUTO_SIGN_DAYS`（默认 3 天）；同一事务内 `stock`：`reserved -= n, in_transit += n`；提交后把订单加入延迟队列，`score = expected_delivered_at`。

**异常 / 分支流程**

| 分支 | 条件 | 处理 |
| --- | --- | --- |
| B1 重复回调 | 同一 `event_id` 第 2…50 次 | 第 3 步拦下，返回 200，零流转（DoD #3） |
| B2 延迟回调 | 订单已被超时取消后才补付成功 | 终态不可变（INV-6），落 `IGNORED(LATE_CALLBACK)`，进人工退款流程 + 告警 |
| B3 乱序回调 | `PAY_FAILED` 与 `PAY_SUCCESS` 先后颠倒 | 各自独立判断，只接受与当前状态相容的那个，不相容落 `IGNORED` |
| B4 支付失败 | `result = PAY_FAILED` | `PENDING_PAYMENT → CANCELLED`，**同事务归还库存**（`reserved → available`），移出延迟队列 |
| B5 退款回调 | `result = REFUND_SUCCESS` | 允许从 `PAID` / `SHIPPED` / `DELIVERED` / `COMPLETED` 进入；库存动作**不在这里做**（见用例 5） |
| B6 验签失败 | 签名不匹配 | 401/403，不落业务数据，安全日志 + 告警 |
| B7 金额不符 | `amount != total_amount` | 不流转，落 `AMOUNT_MISMATCH`，告警 |
| B8 订单不存在 | 查无此单 | 返回 200 + 落 `UNKNOWN_ORDER`（避免支付方无限重推），告警 |
| B9 并发重复投递 | 同一 `event_id` 两个请求同时在飞 | 唯一约束 + 条件更新双保险，只有一个能改到 `PENDING_PAYMENT` 的那一行 |
| B10 发货时状态已变 | 发货前订单被退款/取消 | 条件更新影响行数 = 0，静默退出，不重复扣库存 |

**数据变化**：`payment_events` +1（每次回调）；`payments` +1（成功时）；`orders` 状态与 `paid_at` / `shipped_at` / `expected_delivered_at`；`stock` 发货时 `reserved → in_transit`；Redis 缓存与延迟队列增删。

---

## 用例 3 · 超时取消（Timeout Cancel）

**目标**：未支付订单 30 分钟后自动取消，库存归还；重启不丢任务；并发触发只生效一次。

**触发者**（四种，行为必须完全一致）

1. 延迟队列到期（主通道，下单时入队）
2. 到期扫描兜底（定时任务扫 `PENDING_PAYMENT AND expires_at <= now()`；覆盖队列丢消息、服务长时间宕机 —— **DoD #4 的重启不丢靠这条**）
3. 用户主动取消 `POST /orders/cancel/{id}`
4. 退款申请时订单未发货（见用例 5，复用同一套归还逻辑）

**前置条件**：订单处于 `PENDING_PAYMENT`；`now >= expires_at`（用户主动取消不要求）；用户取消需校验订单归属。

**主流程**

1. 触发源唤起，携带 `order_id` 与 `reason`（`TIMEOUT` / `USER_CANCEL`）。
2. **条件更新**：`UPDATE orders SET status='CANCELLED', cancelled_at=now(), cancel_reason=? WHERE id=? AND status='PENDING_PAYMENT'`。
3. 检查影响行数：`=1` → 继续；`=0` → 已被支付/已取消，**放弃后续动作直接结束**（INV-5、INV-6）。
4. **同一事务**内归还库存：逐项 `reserved -= n, available += n`（调用唯一的 `release_reserved(order_id)`，其他路径也复用它）。
5. 提交事务。
6. 提交后：写 `order_status:{order_id} = CANCELLED`；从延迟队列移除；记业务日志（`order_id` / `reason` / 触发源）。
7. 用户主动取消返回 200 + 最终状态。

> **第 2 步必须是条件更新**：队列到期、扫描兜底、用户点击、退款申请可能同时到达。先 `SELECT` 再 `UPDATE` 在并发下会**重复归还库存**，直接破坏 INV-1。

**异常 / 分支流程**

| 分支 | 条件 | 处理 |
| --- | --- | --- |
| B1 重复触发 | 队列与扫描同时命中 | 影响行数 = 0，静默结束，库存只归还一次（DoD #4） |
| B2 已支付 | 用户在 29:59 完成支付 | 影响行数 = 0，不做任何事（与用例 2 第 7 步移出队列形成双保险） |
| B3 服务重启 | 队列任务丢失 | 扫描兜底捞出到期订单处理（DoD #4） |
| B4 归还失败 | 数据库错误 | 事务回滚，订单保持 `PENDING_PAYMENT`，下次重试（保证 E） |
| B5 订单不存在 | 无效 `order_id` | 404 或日志忽略 + 告警 |
| B6 非本人取消 | 取消他人订单 | 403，不流转 |

**数据变化**：`orders` → `CANCELLED`（`cancelled_at` / `cancel_reason`）；`stock` `reserved → available`；Redis 缓存与延迟队列。

---

## 用例 4 · 自动发货与自动签收（调度器）

**目标**：不依赖任何外部物流，由调度器把订单从 `PAID` 推到 `SHIPPED`、再到 `DELIVERED`，时间可配、可手动拨表。

**触发者**：进程内调度器，`SCAN_INTERVAL`（**默认 5 min**）触发三类任务：

| 任务 | 扫描条件 | 动作 |
| --- | --- | --- |
| 超时取消 | `status='PENDING_PAYMENT' AND expires_at <= now()` | 走用例 3 |
| 自动发货 | `status='PAID' AND auto_ship_at <= now()` | 走**用例 4 · 发货动作** |
| 自动签收 | `status='SHIPPED' AND expected_delivered_at <= now()` | 走**用例 4 · 签收动作** |

**发货动作**（幂等）

1. 条件更新 `UPDATE orders SET status='SHIPPED', shipped_at=now(), expected_delivered_at = now() + AUTO_SIGN_DAYS WHERE id=? AND status='PAID'`。
2. 影响行数为 0 → 订单已非 `PAID`（被退款/取消），静默退出。
3. 同一事务：`stock` 逐项 `reserved -= n, in_transit += n`。
4. 提交后更新缓存、把订单重新入队（`score = expected_delivered_at`）、写业务日志。

**签收动作**（幂等，**按订单状态走正逆两条路**）

1. 条件更新 `UPDATE orders SET status='DELIVERED', delivered_at=now() WHERE id=? AND status='SHIPPED'`。
2. 影响行数为 0 → 静默退出（含 `REFUNDING` / `REFUNDED` / `CANCELLED`，**绝不强行推进**）。
3. 同一事务：逐项 `order_items.delivered_at = now()`。
4. **库存分流（判定轴是订单状态，不是哪个触发源）**：
   - **正向**（订单为 `SHIPPED` → 刚推进到 `DELIVERED`）：`in_transit -= n`，货归用户，**离开 INV-2 恒等式**，转入「已售出」。
   - **逆向**（订单已是 `REFUNDED`，即退款先于签收到达 —— 见用例 5 第 2 路第 6 步）：`in_transit -= n`，**同时**按验货结果 `available += n` 或 `damaged += n`，货回到我方在库口径，**仍留在 INV-2 恒等式内**。
5. 提交后更新缓存、移出队列。
6. `DELIVERED → COMPLETED` 的自动确认收货：`COMPLETED_AFTER_DAYS`（默认 7 天）后再条件更新一次。这是 INV-6 终态前最后一跳，也是退货窗口的边界。

**异常 / 分支流程**

| 分支 | 条件 | 处理 |
| --- | --- | --- |
| B1 多实例并发扫描 | 两个实例同时扫到同一订单 | 条件更新保证只有一个生效，另一个影响行数 = 0 |
| B2 手动发货与自动发货撞车 | 后台点了发货，自动任务也到点 | 同上，条件更新收口 |
| B3 时间被手动改过 | DB 里把 `expected_delivered_at` 改早/改晚 | 无需特殊处理，扫描按新值走；**这是演示和调试的正常手段** |
| B4 调度器停摆 | 进程重启期间错过时间点 | 扫描条件都是 `<= now()`，重启后自然补上，不会漏 |
| B5 发货时库存异常 | `reserved < n`（数据被外部改坏） | 事务回滚 + 告警；不允许把 `reserved` 扣成负数（INV-1） |
| B6 签收时订单已退款 | 签收动作发现订单已是 `REFUNDING` / `REFUNDED` | 条件更新 `WHERE status='SHIPPED'` 直接不命中，**不强行推进**；随后**由退货流程接管**（见用例 5 第 2 路第 6 步）：货到仓 → 验货 → `available` 或 `damaged`。这条是「在途退款」与「签收」竞态的正确出口 |

**数据变化**：`orders` 状态与三个时间戳；`order_items.delivered_at`；`stock` 阶段性转移；Redis 缓存与延迟队列。

**手动端点**（对应决策 J，供演示与调试）

- `POST /admin/orders/ship/{id}` —— 手动发货，走**同一个**发货动作
- `POST /admin/orders/deliver/{id}` —— 手动签收，走**同一个**签收动作

> 手动路径与自动路径**共用同一个服务方法**，不允许各写一份。否则两条路的幂等与库存语义会分叉，DoD #4 就没法验证。

---

## 用例 5 · 退款与退货（Refund & Return）

**目标**：用户在**任意时刻**都能申请退款：没发货就取消订单归还库存，已发货/已签收就走退货流程 —— 钱立刻退，库存等**货回到仓库**再还。

**触发者**

1. **用户申请**：`POST /orders/refund/{id}`（决策 J 保留的手动端点 —— 「用户手动操作」的主入口）
2. 支付方的 `REFUND_SUCCESS` 回调（钱退成功的事实）
3. 调度器（退货包裹的签收入库，见用例 4 签收动作）

**前置条件**：订单处于 `PAID` / `SHIPPED` / `DELIVERED` / `COMPLETED` 之一；申请人为订单所有者；v1 校验「必须退全部订单项」（决策 I）。

**主流程 —— 按申请时的订单状态分路**

**第 1 路：`PAID`（已付款、未发货）—— 货还在仓库**

1. 条件更新 `UPDATE orders SET status='REFUNDING', refund_requested_at=now(), cancel_reason='USER_REFUND' WHERE id=? AND status='PAID'`。
2. 影响行数为 0 → 状态已变，返回 409。
3. 同一事务：调用 `release_reserved(order_id)` 归还库存（`reserved → available`，**货从没离开仓库，立即可售**）。
4. 逐项 `order_items.refund_status = 'REFUNDING'`；写 `refunds`；事务提交后从延迟队列移除。
5. 调支付方退款 API；收到 `REFUND_SUCCESS` 回调后 → `orders.status = 'REFUNDED'`、`refunds.status = 'SUCCESS'`、逐项 `refund_status = 'REFUNDED'`。
6. 返回 `202`：`{ refund_id, status: "REFUNDING" }`。

**第 2 路：`SHIPPED`（已发货、未签收）—— 货在路上**

1. 条件更新 `WHERE id=? AND status='SHIPPED'` → `REFUNDING`。
2. 同一事务：**库存完全不动**。货在途，此刻加回 `available` 会制造「显示有货、实际发不出」的新式超卖。记录 `order_items.refund_shipped_at = now()` 以备对账。
3. 尝试拦截（v1 只记录 `intercept_requested_at`，不接真实物流 API；开发环境等同拦截失败）。
4. 拦截失败则包裹照常送达，用户拒收或退回；包裹回到仓库签收时才动库存。
5. 退款走支付方流程，`REFUND_SUCCESS` 后订单入 `REFUNDED`。
6. **签收时刻的库存动作**（`REFUNDED` 之后仍可能发生）：货到仓即走**用例 4 · 签收动作第 4 步的逆向分支** —— `in_transit -= n`，验货合格 `available += n`、不合格 `damaged += n`。判定轴是**订单状态**（`REFUNDED` → 逆向），不是触发源；这条与第 3 路共用同一份入库逻辑。

**第 3 路：`DELIVERED` / `COMPLETED`（已签收）—— 货在用户手上**

1. 条件更新 `WHERE id=? AND status IN ('DELIVERED','COMPLETED')` → `REFUNDING`，记 `refund_requested_at`。
2. 同一事务：写 `refunds`、逐项 `refund_status='REFUNDING'`。**库存不动** —— 货在用户手上。
3. 用户在 N 天内寄回（v1 不接逆向物流，开发环境用 `POST /admin/orders/return-received/{id}` 手动触发，或调度器在 `AUTO_RETURN_DAYS` 后自动触发）。
4. 退货包裹回到仓库签收：`stock` `in_transit -= n`，验货合格 → `available += n`；不合格 → `damaged += n`；逐项写 `return_received_at`、`return_condition = GOOD | DAMAGED`。
5. 订单入 `REFUNDED`（若第 3 步已入则保持），终态不可再变。

**异常 / 分支流程**

| 分支 | 条件 | 处理 |
| --- | --- | --- |
| B1 重复申请 | 同一订单再点一次退款 | `refund_status != NONE` → `409 REFUND_ALREADY_REQUESTED`，**不重复退款、不重复归还库存** |
| B2 多商品订单 | items > 1 | v1 强制整单退；若请求只带了部分项 → `400 PARTIAL_REFUND_NOT_SUPPORTED`（明确告知而非静默忽略） |
| B3 并发：退款申请 vs 自动签收 | 用户点退款时签收任务同时命中 | 两个条件更新的 `WHERE status` 只有一个能赢；输的一方静默退出。**赢的是谁都能自洽**：签收赢 → 走第 3 路；退款赢 → 走第 2 路 |
| B4 验货不合格 | 退回的商品有损坏 | 库存进 `damaged`（不参与可售），订单仍 `REFUNDED`（钱照退，货损另行处理） |
| B5 退款失败 | 支付方退款 API 报错 | `refunds.status = 'FAILED'`，订单**保持 `REFUNDING`**，可重试；不得提前入 `REFUNDED` |
| B6 订单已被取消 | 申请退款时是 `CANCELLED` | `409 ORDER_NOT_REFUNDABLE`（钱没收到，无可退） |
| B7 商品已删除 | 商品下架/被删 | 用 `order_items` 的价格与数量快照计算退款额，不依赖商品表 |
| B8 退货包裹丢失 | 超期未签收 | 保持 `REFUNDING`，进人工处理队列并告警（v1 只告警不自动处理） |

**数据变化**

- `refunds`：+1（含 `status` / `amount` / `provider_refund_id`）
- `orders`：`status` / `refund_requested_at` / `cancelled_at`（第 1 路）
- `order_items`：`refund_status` / `refund_shipped_at` / `return_received_at` / `return_condition`
- `stock`：第 1 路 `reserved → available`；第 2、3 路的归还**发生在包裹签收时刻**，`in_transit → available | damaged`
- Redis：`order_status:{order_id}`；延迟队列增删

---

## 用例 6 · 撤销退款申请（Revoke Refund）

**目标**：用户在退款还没真正发生时反悔，把订单退回申请退款之前的状态。这是 `REFUNDING` 唯一的「往回走」的出口。

**触发者**：用户 `POST /orders/refund-revoke/{id}`（或客服代操作）。

**前置条件**（两条硬条件，缺一不可）

| 条件 | 判定依据 | 理由 |
| --- | --- | --- |
| **钱还没退出去** | `refunds.status IN ('PENDING','CREATED')` | 钱一旦退出（`SENT`），撤销就变成「再收一次钱」——【需人工介入】，系统不做 |
| **货没到仓** | 全部 `order_items.return_received_at IS NULL` | 货已入库，撤销要重新出库，库存语义与实物位置会脱节 |

**主流程**

1. 读取订单，确认状态为 `REFUNDING`（或整单场景下的 `PARTIALLY_REFUNDED`）。
2. 校验上面两条硬条件；不满足则返回 409 并打【需人工介入】标注。
3. 读取 `order_items.refund_from_status`（申请退款时记录的原状态）—— **撤销的终点不是固定状态，而是它**。
4. **一个事务**内：
   - 条件更新 `orders.status` 回到 `refund_from_status`；
   - 逐项改写 `order_items.refund_status`：**钱未曾发出 → `'NONE'`；钱曾发出过（`refunds.status='SENT'`）→ `'REVOKED'`**；清空 `refund_shipped_at`；
   - `refunds.status = 'REVOKED'`；
   - **仅当原状态是 `PAID`**（货从未离仓）：**反向预占** `available -= n`、`reserved += n`（与申请退款时的归还是严格互逆的）。
5. 提交后：更新 `order_status` 缓存；若支付方接口支持，尝试取消在途的退款请求。
6. 返回 `200` + 恢复后的订单状态。

**异常 / 分支流程**

| 分支 | 条件 | 处理 |
| --- | --- | --- |
| B1 钱已退出 | `refunds.status='SENT'` | 拒绝 `409 REFUND_ALREADY_SENT` +【需人工介入】#1 |
| B2 货已到仓 | 存在 `return_received_at` | 拒绝 `409 RETURN_ALREADY_RECEIVED` +【需人工介入】 |
| B3 原状态是已签收 | `refund_from_status IN ('DELIVERED','COMPLETED')` | **不允许撤销** `409 REFUND_NOT_REVOCABLE_SIGNED` +【需人工介入】#8（货已在用户手上，退货动作已发生） |
| B4 反向预占失败 | 原状态是 `PAID`，但 `available < n`（库存已被别人买走） | **整个撤销回滚**，订单保持 `REFUNDING`，`409 REFUND_REVOKE_STOCK_UNAVAILABLE` +【需人工介入】#7。绝不允许把 `available` 扣成负数（INV-1），也不允许「状态退了但库存没退」 |
| B5 重复撤销 | 订单已不在 `REFUNDING` | `409 REFUND_NOT_REVOCABLE`，无副作用 |
| B6 原状态是在途 | `refund_from_status='SHIPPED'` | 允许：回到 `SHIPPED`，货继续送往用户，**库存不动**（维持在 `in_transit`） |

**数据变化**：`orders.status`（回到原状态）；`order_items.refund_status`（`'NONE'` 或 `'REVOKED'`，见第 4 步）；`refunds.status='REVOKED'`；`stock` 仅在回 `PAID` 的场景反向预占。

**两个容易丢的事实**（必须落库，否则后面解释不清）：

1. **撤销后仍要保留「钱曾发出过」**：若撤销前 `refunds.status` 已经是 `SENT`，则 `refund_status` 记 `'REVOKED'` 而不是 `'NONE'`，并打【需人工介入】#1。丢了它就会变成「系统认为没退过款，用户却收到了钱」。
2. **撤销成功后允许重新申请退款**：`refund_status IN ('NONE','REVOKED')` 都可以作为再次申请的前置，否则用户撤销后就再也退不了了。

**新增字段需求（交给 D4）**：`order_items.refund_from_status`（申请退款时的订单状态）、`order_items.refund_status` 需含 `REVOKED` 取值、`refunds.status` 需含 `PENDING` / `CREATED` / `SENT` / `SUCCESS` / `FAILED` / `REVOKED`。**没有 `refund_from_status` 就无法实现撤销** —— 这是本用例对表结构提出的硬要求。

---

## 三条关键语义的收口

| 语义 | 触发点 | 库存动作 |
| --- | --- | --- |
| **支付失败** | `PENDING_PAYMENT` 阶段收到 `PAY_FAILED` | 立即 `reserved → available`（钱压根没收到） |
| **超时取消** | 30 分钟未支付 | 立即 `reserved → available`（货没动过） |
| **发货前退款** | `PAID` 阶段申请退款 | 立即 `reserved → available`（货没动过） |
| **发货后退款** | `SHIPPED` / `DELIVERED` / `COMPLETED` 申请退款 | **不动**；等退货包裹签收 → `in_transit → available \| damaged` |

> 一句话原则：**钱的状态和货的状态是两条独立的线，库存永远跟着货走，不跟着钱走。**
>
> 实现上只允许存在一份归还逻辑（`release_reserved(order_id)`）和一份签收入库逻辑，所有路径共用。

## 最易出错的交汇点

| 交汇 | 风险 | 收口 |
| --- | --- | --- |
| 支付 vs 超时取消 | 最后一秒支付，两流程同时改同一行 | 都用 `WHERE status='PENDING_PAYMENT'` 条件更新，DB 决定唯一赢家，输方静默退出 |
| 退款申请 vs 自动签收 | 点退款的瞬间签收任务命中 | 同上，条件更新；两种结果都自洽（第 2 路或第 3 路） |
| 支付成功后延迟队列残留 | 已支付订单 30 分钟后被取消 | 支付后主动移出队列 + 条件更新双保险 |
| 在途退款时把库存加回 | 货在路上却显示可售 | 第 2 路**绝不碰库存**，归还只在签收时刻 |
| 两种幂等机制混淆 | 以为是同一回事 | `Idempotency-Key` 管用户请求重复，`event_id` 管支付方通知重复，不同表、不同生命周期 |
| 多实例调度器 | 两个实例同时推进同一订单 | 所有状态推进都是条件更新，不依赖进程内锁 |
| 扫描周期 5 min 的精度 | 超时取消的**兜底路径**最坏晚 5 min 生效；自动签收启动时最多晚 5 min 触发 | 超时取消的**主通道是延迟队列**（秒级精度），扫描只是兜底，5 min 的偏差可接受；自动签收本身只需天内精度 |
| 撤销退款 vs 退款回调 | 用户点撤销的同时支付方回了 `REFUND_SUCCESS` | 两条都是条件更新：撤销要 `refunds.status IN ('PENDING','CREATED')`，回调要 `status='REFUNDING'`。**钱的状态由 `refunds.status` 定唯一赢家**，撤销赢则回调落 `IGNORED`（钱其实已退，进【需人工介入】） |
| 撤销退款的反向预占 | 撤销时货已被别人买走，`available < n` | 整个撤销回滚，订单保持 `REFUNDING`，返回 409。**不允许把 available 扣成负数，也不允许「状态退了库存没退」** |

## 实现范围

**v1 实现（W1–W10）**

- 用例 1（下单 + 幂等 + 预占）
- 用例 2（回调幂等 + 金额校验 + 乱序处理 + 自动发货）
- 用例 3（超时取消 + 扫描兜底）
- 用例 4（自动发货 3 天签收 + 手动发货/签收端点）
- 用例 5 的**第 1 路与第 3 路**（发货前退款、已签收退款；用 Admin 端点模拟退货签收）
- 用例 6（撤销退款申请，含反向预占与失败回滚）

**已设计、本阶段不实现**

- 真实物流方对接（发货/签收/逆向物流回调）—— 用调度器与 Admin 端点代替
- 第 2 路的真实拦截 API（v1 只记 `intercept_requested_at`）
- 部分退货（数据模型已按订单项设计，放开只需删掉一条校验）
- 售后退款之外的逆向场景（换货、维修）
- **一切人工介入功能** —— 没有工单、没有审批流、没有人工改状态的接口（见下）

## 【需人工介入】标注约定

**本项目不实现任何人工介入功能。** 凡系统无法自动得出唯一正确结果的情形，一律：

1. 在文档/代码注释中打上 **【需人工介入】** 标注；
2. 系统行为统一为「**停在中间态 + 落库 + 告警**」，不猜着往下走；
3. 完整清单见 `02-state-machine.md` 第 10 节（11 个场景，含撤销退款失败、退款重试超限、金额不符、延迟回调、退货超期未入库等）。

> 原则：猜错的代价（错退钱、错扣库存）远高于停在中间态让人来看一眼。这也是 `REFUNDING` 必须是**可长时间停留**的状态的原因 —— 它同时承载「正在退」「退失败等人看」「等退货入库」三种情形。

## 待 D2–D4 承接的问题

1. **D2 状态机**：状态集合确定为 9 个 —— `PENDING_PAYMENT` / `PAID` / `SHIPPED` / `DELIVERED` / `COMPLETED` / `REFUNDING` / `PARTIALLY_REFUNDED` / `REFUNDED` / `CANCELLED`（详见 `02-state-machine.md`，该文档是唯一真相源），每个转移的触发者与前置条件直接取自本文各用例的分支表。
2. **D3 API 契约**：直接以 §0「路由约定」的 16 个端点清单为输入，逐个补请求/响应 schema 与状态码。需特别覆盖：
   - 错误码：`STOCK_INSUFFICIENT`、`IDEMPOTENCY_KEY_REUSED`、`IDEMPOTENCY_IN_PROGRESS`、`PRODUCT_OFF_SALE`、`ORDER_NOT_CANCELLABLE`、`ORDER_NOT_REFUNDABLE`、`REFUND_ALREADY_REQUESTED`、`REFUND_ALREADY_SENT`、`REFUND_NOT_REVOCABLE_SIGNED`、`REFUND_REVOKE_STOCK_UNAVAILABLE`、`RETURN_ALREADY_RECEIVED`、`PARTIAL_REFUND_NOT_SUPPORTED`、`INVALID_STATE_TRANSITION`、`VALIDATION_ERROR`
   - 统一响应包体与错误结构（D6 的错误层雏形要跟它对齐）；错误结构需能承载【需人工介入】标记
   - 16 个略超 8–12 的要求，若需精简优先砍 #11 `mock-success`（开发便利，可用手动拨表替代）与 #15 `admin/orders`（可先只留 `REFUNDING` 筛选）
3. **D4 表字段草案**：至少 7 张表 —— `orders` / `order_items` / `stock` / `payments` / `payment_events` / `refunds` / `idempotency_keys`。新增硬要求：
   - `order_items.refund_from_status`（**撤销退款必需**，不记就无法回到原状态）
   - `order_items.refund_shipped_at` / `return_received_at` / `return_condition`
   - `refunds.status` 需含 `PENDING` / `CREATED` / `SENT` / `SUCCESS` / `FAILED` / `REVOKED`（撤销判定依赖 `SENT` 这个区分）
   - `orders.auto_ship_at` / `expected_delivered_at`（调度器拨表用）
4. **待定**：`COMPLETED_AFTER_DAYS`（自动确认收货，默认 7 天）、`AUTO_RETURN_DAYS`（退货入库超期，建议 15 天）、`MAX_REFUND_RETRY`（建议 5 次）的取值；`damaged` 库存的处置（v1 只记账 + 打【需人工介入】标注）。
