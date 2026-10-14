# 03 · API 契约与错误码规范

> 阶段 0 · D3 产出物
>
> 上游：`01-usecases.md`（路由约定 + 16 个端点）· `02-state-machine.md`（状态与错误码）
> 下游：`04-dod.md`（表字段草案）、W3 的 OpenAPI/TS 类型生成、D6 的错误层雏形
>
> **本文档定义三件事**：请求/响应长什么样、错误怎么表达、所有数字常量取多少。
> 端点清单与路径风格已在 `01-usecases.md` §0 定死，本文不重复讨论，只补契约细节。

## 1. 硬约定：`///` 文档注释

**状态码、错误码、常量三者在代码里必须带 `///` 文档注释。** 这不是「建议」，是编译期可检查的纪律 —— 目的有三个：

1. **契约与代码不分叉**：文档里的错误码语义就在枚举旁边，改代码时不会忘。
2. **OpenAPI 自动生成的前提**：`utoipa` / `schemars` 这类工具直接读 `///` 产出 description 与 enum 说明，不写注释生成的文档就是空壳（DoD #5 要求「全部接口有 OpenAPI 文档 + 前端 TS 类型自动生成」）。
3. **前端对接零猜测**：TS 类型由这些枚举生成，`///` 会变成 IDE 里的 hover 提示。

### 规则

| 规则 | 说明 |
| --- | --- |
| 作用范围 | 所有 `pub` 的枚举、结构体、字段、函数、常量，以及**枚举的每一个变体** |
| `///` vs `//` | `///` 是对外契约（会进 OpenAPI / TS 类型）；`//` 是实现细节（不外露）。**判断标准：这句话前端需不需要知道** |
| 每条 `///` 必含 | ① 中文语义 ② 触发条件（什么情况下会出现）③ 客户端该怎么办 |
| 状态码/错误码额外必含 | 对应的 **HTTP 状态码** 与**是否可重试** |
| 序列化名 | 用 `#[serde(rename_all = "SCREAMING_SNAKE_CASE")]` 统一，不用逐字段手写 |
| 禁止 | 写「错误码」「状态」这类同义反复；`///` 必须提供新信息 |

### 示例（本项目所有枚举照此办理）

```rust
/// 订单状态。业务状态的唯一真相源，合法转移见 docs/02-state-machine.md。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum OrderStatus {
    /// 已创建、等待支付。此时库存已预占（reserved），30 分钟未支付会被自动取消。
    PendingPayment,
    /// 已付款、未发货。货仍在仓库，库存挂在 reserved。
    Paid,
    /// 已发货、未签收。货在途，库存挂在 in_transit。
    Shipped,
    /// 已签收、退货窗口内（默认 7 天）。货已交付用户，不再计入我方库存。
    Delivered,
    /// 已确认收货，交易完结。终态，不可再变。
    Completed,
    /// 退款/退货处理中。钱可能已退、货可能没回；该状态可长时间停留。
    Refunding,
    /// 钱已退但货仍在途。半终态，收尾后进入 REFUNDED。
    PartiallyRefunded,
    /// 已退款完结。终态，但退货包裹仍可能在途（届时补记库存）。
    Refunded,
    /// 已取消（从未成交）。终态，用于「钱没收到」的退出场景。
    Cancelled,
}
```

## 2. 通用约定

| 项 | 约定 |
| --- | --- |
| Base URL | 无版本前缀，由部署环境承担（本地 `http://localhost:3000`） |
| 认证 | `Authorization: Bearer <token>`（W5 落地；D3 阶段契约先占位） |
| Content-Type | `application/json; charset=utf-8`，请求与响应均如此 |
| 幂等键 | `Idempotency-Key: <uuid>`，**仅 `POST /orders` 必须** |
| 请求追踪 | 响应头必带 `X-Request-Id`（回显请求头同名值，缺失则服务端生成，D6 中间件实现） |
| 限流响应头 | `429` / `503` 必带 `Retry-After: <秒>`（W6 落地） |
| 时间格式 | **RFC3339 UTC**，如 `2025-03-12T08:30:00Z`。不用时间戳数字 |
| ID 类型 | 订单/支付/退款 ID 为 **UUID 字符串**；商品 ID 为整数 |
| **金额** | **整数，单位为分**（`amount: 12900` = ¥129.00）。**绝不用浮点数**，前端负责除以 100 展示 |
| 数量 | 正整数，单次下单单项上限 `MAX_ITEM_QUANTITY` |
| 分页 | `?page=1&page_size=20`，`page_size` 上限 50；响应 `meta` 返回 `total` / `has_more` |
| 排序 | `?sort=created_at:desc`（默认按 `created_at` 倒序） |
| 空值 | 用 `null`，不用空字符串或 `0` 代替 |

## 3. 统一响应包体

### 成功

```json
{
  "code": 0,
  "message": "ok",
  "data": { "...": "业务数据" },
  "request_id": "01932f4e-8a1b-7c3d-9e2f-1a2b3c4d5e6f"
}
```

列表类额外带 `meta`：

```json
{
  "code": 0,
  "message": "ok",
  "data": [ "..." ],
  "meta": { "total": 137, "page": 1, "page_size": 20, "has_more": true },
  "request_id": "..."
}
```

### 失败

```json
{
  "code": 40901,
  "message": "库存不足",
  "error": {
    "code": "STOCK_INSUFFICIENT",
    "detail": { "product_id": 1001, "requested": 2, "available": 1 },
    "retryable": false,
    "manual_intervention": false
  },
  "request_id": "..."
}
```

| 字段 | 说明 |
| --- | --- |
| `code` | **数字错误码**，`0` 表示成功。前端做 switch 分流用这个 |
| `message` | 面向人的中文描述，**仅供展示，前端不要用它做判断** |
| `error.code` | **字符串错误码**，与 `ErrorCode` 枚举一一对应。前端做类型判断/日志检索用这个 |
| `error.detail` | 结构化上下文，便于前端定位是哪个商品/哪个字段出错；无附加信息时为 `null` |
| `error.retryable` | 客户端**能否原样重试**。`true` 表示可直接重试（如 `IDEMPOTENCY_IN_PROGRESS`） |
| `error.manual_intervention` | 是否已登记为【需人工介入】场景（见 `02-state-machine.md` 第 10 节）。`true` 时前端应展示「客服将联系您」而不是「请重试」 |
| `request_id` | 与响应头一致，报障时提供给后端查日志 |

> **为什么数字码和字符串码都有**：数字码给前端做紧凑的 `switch`，字符串码给人看和检索。两者由同一个枚举派生（`#[serde(rename)]` + `fn as_number()`），不会不一致。

## 4. HTTP 状态码规范

**本项目只使用下列 11 个状态码**（9 个通用 + 401/403 两个认证授权类）。每一条都必须在代码里有 `///` 注释说明触发条件。

| 状态码 | 语义 | 何时使用 | 客户端该怎么办 |
| --- | --- | --- | --- |
| `200 OK` | 成功 | 查询成功；**失败类回调也返回 200**（见下） | 正常处理 `data` |
| `201 Created` | 创建成功 | `POST /orders` 下单成功 | 从响应取 `order_id` |
| `202 Accepted` | 已受理、异步处理中 | `POST /orders/refund/{id}`（退款要先调支付方，最终结果由回调决定） | 轮询 `GET /orders/{id}` 或等推送 |
| `400 Bad Request` | 请求格式或参数非法 | 字段缺失、类型错、金额为负、部分退货请求 | 检查请求体，**不要重试** |
| `401 Unauthorized` | 未认证 | 缺 token、token 过期、**回调验签失败** | 跳登录；回调场景记安全日志 |
| `403 Forbidden` | 已认证但无权限 | 访问他人订单、非管理员调 Admin 接口 | 不要重试，提示无权限 |
| `404 Not Found` | 资源不存在 | 订单/商品不存在 | 提示资源不存在 |
| `409 Conflict` | **状态冲突（本项目最常用）** | 库存不足、幂等冲突、状态不可流转、退款不可撤销 | 按 `error.code` 分流；`retryable=true` 才重试 |
| `429 Too Many Requests` | 触发限流 | W6 落地 | 按 `Retry-After` 退避重试 |
| `500 Internal Server Error` | 服务端异常 | 未预期错误（数据库断连、panic 捕获） | 可重试，需带 `X-Request-Id` 报障 |
| `503 Service Unavailable` | 依赖不可用或正在关闭 | Postgres/Redis 不可达、优雅停机中 | 按 `Retry-After` 重试 |

### 两条容易搞反的规则

1. **支付方回调的状态不匹配，也要返回 `200`** —— 返回 4xx/5xx 会让支付方**无限重推**。状态不匹配的差异记在 `payment_events.status = IGNORED`，业务上报警，协议上成功。
2. **`202` 只用于「已受理但结果未定」** —— 退款申请就是典型：钱还没退，最终状态由支付方回调决定。不要用它做「我收下了但还没处理」的偷懒响应。

## 5. 错误码总表

**所有错误码集中于 `api/src/error.rs` 的 `ErrorCode` 枚举**（或 `domain/src/error.rs`，取决于是否需要被 domain 引用）。下表每一项都必须在代码里有对应 `///` 注释。

### 5.1 校验与资源类（HTTP 400 / 404）

| 数字码 | 字符串码 | HTTP | 触发条件 | 可重试 |
| --- | --- | --- | --- | --- |
| 40001 | `VALIDATION_ERROR` | 400 | 请求体字段缺失、类型错、`quantity <= 0`、items 为空 | ✗ |
| 40002 | `PARTIAL_REFUND_NOT_SUPPORTED` | 400 | 退款请求只带了部分订单项（v1 只支持整单退） | ✗ |
| 40401 | `PRODUCT_NOT_FOUND` | 404 | 商品不存在 | ✗ |
| 40402 | `ORDER_NOT_FOUND` | 404 | 订单不存在（或不属于当前用户，避免泄露存在性） | ✗ |

### 5.2 认证授权类（HTTP 401 / 403）

| 数字码 | 字符串码 | HTTP | 触发条件 | 可重试 |
| --- | --- | --- | --- | --- |
| 40101 | `UNAUTHORIZED` | 401 | 缺 token 或 token 无效/过期 | ✗ |
| 40102 | `INVALID_SIGNATURE` | 401 | 支付回调验签失败（可能伪造）。**不落任何业务数据**，记安全日志 + 告警 | ✗ |
| 40301 | `FORBIDDEN` | 403 | 访问他人订单、非管理员调 Admin 接口 | ✗ |

### 5.3 库存与商品状态类（HTTP 409）—— DoD #1 主战场

| 数字码 | 字符串码 | HTTP | 触发条件 | 可重试 |
| --- | --- | --- | --- | --- |
| 40901 | `STOCK_INSUFFICIENT` | 409 | 预占时 `available < n`。**事务回滚，不创建订单** | ✗ |
| 40902 | `PRODUCT_OFF_SALE` | 409 | 商品存在但非 `ON_SALE` | ✗ |

### 5.4 幂等类（HTTP 409）—— DoD #2 主战场

| 数字码 | 字符串码 | HTTP | 触发条件 | 可重试 |
| --- | --- | --- | --- | --- |
| 40911 | `IDEMPOTENCY_KEY_REUSED` | 409 | 同一 `Idempotency-Key` 配了**不同的请求体**（指纹不符） | ✗ |
| 40912 | `IDEMPOTENCY_IN_PROGRESS` | 409 | 同一 key 的首次请求仍在处理中 | **✓** 稍后原样重试可命中「回放首次响应」 |

### 5.5 状态流转与金额类（HTTP 409）

| 数字码 | 字符串码 | HTTP | 触发条件 | 可重试 |
| --- | --- | --- | --- | --- |
| 40921 | `INVALID_STATE_TRANSITION` | 409 | 目标状态与当前状态不相容（如对已发货订单发货） | ✗ |
| 40922 | `ORDER_NOT_CANCELLABLE` | 409 | 对 `PAID` 及之后的订单调取消（钱已收，只能走退款） | ✗ |
| 40923 | `ORDER_NOT_REFUNDABLE` | 409 | 对 `PENDING_PAYMENT` / `CANCELLED` 申请退款（钱没收到，无可退） | ✗ |
| 40924 | `ORDER_ALREADY_FINAL` | 409 | 对终态订单发起任何流转（INV-6） | ✗ |
| 40925 | `AMOUNT_MISMATCH` | 409 | 回调金额 ≠ 订单金额。**状态零流转** +【需人工介入】#3 | ✗ |

### 5.6 退款与退货类（HTTP 409）

| 数字码 | 字符串码 | HTTP | 触发条件 | 可重试 | 人工介入 |
| --- | --- | --- | --- | --- | --- |
| 40931 | `REFUND_ALREADY_REQUESTED` | 409 | 订单已有在途退款 | ✗ | — |
| 40932 | `REFUND_ALREADY_SENT` | 409 | 撤销时钱已发出（`refunds.status='SENT'`） | ✗ | **#1** |
| 40933 | `REFUND_NOT_REVOCABLE_SIGNED` | 409 | 对已签收订单（`DELIVERED`/`COMPLETED`）申请撤销 | ✗ | **#8** |
| 40934 | `REFUND_REVOKE_STOCK_UNAVAILABLE` | 409 | 撤销时反向预占失败（库存已被买走）。**整个撤销回滚** | ✗ | **#7** |
| 40935 | `RETURN_ALREADY_RECEIVED` | 409 | 撤销时货已到仓（有 `return_received_at`） | ✗ | ✓ |
| 40936 | `REFUND_NOT_REVOCABLE` | 409 | 对非 `REFUNDING` / `PARTIALLY_REFUNDED` 的订单申请撤销 | ✗ | — |

### 5.7 服务端与依赖类（HTTP 429 / 500 / 503）

| 数字码 | 字符串码 | HTTP | 触发条件 | 可重试 |
| --- | --- | --- | --- | --- |
| 42901 | `RATE_LIMITED` | 429 | 触发限流（W6 落地）。带 `Retry-After` | **✓** |
| 50001 | `INTERNAL_ERROR` | 500 | 未预期异常（含 panic 捕获） | ✓ |
| 50301 | `SERVICE_UNAVAILABLE` | 503 | Postgres/Redis 不可达、优雅停机中 | **✓** |

### 5.8 代码形态（`///` 强制）

```rust
/// 业务错误码。数字码与字符串码一一对应，前端用 code 分流、用字符串码检索日志。
///
/// `retryable` 决定客户端能否原样重试；`manual_intervention` 为 true 时
/// 表示该场景已登记为【需人工介入】（见 docs/02-state-machine.md 第 10 节），
/// 前端应提示「客服将联系您」而非「请重试」。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    /// 请求参数非法。触发：字段缺失、类型错误、数量非正、items 为空。
    /// HTTP 400。不可重试。
    ValidationError,

    /// 不支持部分退货。触发：退款请求未覆盖订单全部项（v1 只支持整单退）。
    /// HTTP 400。不可重试。
    PartialRefundNotSupported,

    /// 库存不足。触发：预占时 `available < requested`，事务回滚且不创建订单。
    /// HTTP 409。不可重试 —— 重试仍会失败，应由前端提示「已售罄」。
    StockInsufficient,

    /// 幂等键冲突。触发：同一 Idempotency-Key 携带了不同的请求体。
    /// HTTP 409。不可重试 —— 这是客户端 bug，应换新 key。
    IdempotencyKeyReused,

    /// 首次请求仍在处理中。触发：同一 Idempotency-Key 的并发重复提交。
    /// HTTP 409。**可重试** —— 稍后原样重试会命中回放首次响应（DoD #2）。
    IdempotencyInProgress,

    // ...（其余变体同格式，逐条对照第 5.1–5.7 节补齐）
}

impl ErrorCode {
    /// 数字错误码，用于响应体的 `code` 字段（0 表示成功，故错误码从 10000 起）。
    pub fn as_number(self) -> u32 { /* ... */ }

    /// 对应的 HTTP 状态码。
    pub fn http_status(self) -> StatusCode { /* ... */ }

    /// 客户端能否原样重试。
    pub fn retryable(self) -> bool { /* ... */ }

    /// 是否属于【需人工介入】场景，决定前端展示「客服将联系您」还是「请重试」。
    pub fn manual_intervention(self) -> bool { /* ... */ }

    /// 面向用户的中文描述，写入响应体 `message`。仅用于展示。
    pub fn message(self) -> &'static str { /* ... */ }
}
```

## 6. 状态与枚举的 `///` 清单

除错误码外，下列类型也必须逐变体写 `///`（它们是 TS 类型的直接来源）：

| 类型 | 变体 | 备注 |
| --- | --- | --- |
| `OrderStatus` | 9 个 | 见 §1 示例，已给出完整写法 |
| `OrderEvent` | 13 个 | 内部事件，是否需要暴露给前端取决于是否做订单事件流（v1 不暴露，可不加 `ToSchema`） |
| `PaymentResult` | `PAY_SUCCESS` / `PAY_FAILED` / `REFUND_SUCCESS` | 回调入参，需 `///` 说明各自的状态流转后果 |
| `PaymentEventStatus` | `PROCESSED` / `IGNORED` / `AMOUNT_MISMATCH` / `UNKNOWN_ORDER` | 管理端排障用，`///` 必须写清「什么情况会落到这个值」 |
| `RefundStatus` | `PENDING` / `CREATED` / `SENT` / `SUCCESS` / `FAILED` / `REVOKED` | **`SENT` 是关键分界**：撤销能否成功、`refund_status` 记 `NONE` 还是 `REVOKED` 全靠它 |
| `RefundStatus`（订单项） | `NONE` / `REFUNDING` / `REFUNDED` / `REVOKED` | `REVOKED` 语义见 `02-state-machine.md` §2 —— 表示「曾申请过且钱发出过」 |
| `ReturnCondition` | `GOOD` / `DAMAGED` | 退货验货结果，决定库存进 `available` 还是 `damaged` |
| `CancelReason` | `TIMEOUT` / `USER_CANCEL` / `USER_REFUND` | 取消原因，对账与排障用 |

> **未在文档中定义的枚举不要凭空造**：需要新增时先改本文档与 `02-state-machine.md`，再写代码。契约文档是上游。

## 7. 常量清单（全部 `///` 强制）

**所有魔法数字禁止散落在代码里**，统一收敛到 `infra/src/config.rs`（环境变量可覆盖）。每一项都必须有 `///` 说明「单位、默认值、调大调小的影响」。

```rust
/// 订单支付超时。超时后订单自动取消并归还库存（DoD #4）。
/// 单位：分钟。默认 30。调小会让用户付款时间变紧，调大则库存被占用更久。
pub const ORDER_TIMEOUT_MINUTES: u64 = 30;

/// 支付成功后自动发货的延迟。0 表示立即发货。
/// 单位：秒。默认 300（5 分钟，演示用）。生产环境可设为 0 或按仓库作业节奏调大。
pub const AUTO_SHIP_DELAY_SECONDS: u64 = 300;

/// 发货后自动签收的时长。不接物流回调，到期由调度器标记 DELIVERED。
/// 单位：天。默认 3。调大 = 退货窗口更宽，库存更难预测。
pub const AUTO_SIGN_DAYS: u64 = 3;

/// 签收后自动确认收货的时长（进入 COMPLETED 终态）。
/// 单位：天。默认 7。这是退货窗口的边界，调大则售后期更长。
pub const COMPLETED_AFTER_DAYS: u64 = 7;

/// 退货包裹的超期天数。超过仍无 return_received_at 则告警。
/// 单位：天。默认 15。触发【需人工介入】#5。
pub const AUTO_RETURN_DAYS: u64 = 15;

/// 调度器扫描周期。覆盖超时取消兜底、自动发货、自动签收、自动确认收货。
/// 单位：秒。默认 300（5 分钟）。调小 = 更及时但数据库压力更大；
/// 注意超时取消的主通道是延迟队列，本项只是兜底，5 分钟的偏差可接受。
pub const SCAN_INTERVAL_SECONDS: u64 = 300;

/// 退款失败的自动重试上限。超过后停止重试并告警。
/// 默认 5。触发【需人工介入】#2。
pub const MAX_REFUND_RETRY: u32 = 5;

/// Idempotency-Key 的保留时长。过期后同一 key 可再次使用。
/// 单位：小时。默认 24。调小可能导致「同一 key 的新请求被误判为新单」。
pub const IDEMPOTENCY_TTL_HOURS: u64 = 24;

/// 单次下单单个商品项的数量上限。
/// 默认 10。用于拦住脚本误操作与恶意刷单，也保护 total_amount 不溢出。
pub const MAX_ITEM_QUANTITY: u32 = 10;

/// 单笔订单的商品项数量上限。
/// 默认 20。与 MAX_ITEM_QUANTITY 共同界定订单规模。
pub const MAX_ORDER_ITEMS: usize = 20;

/// 列表接口默认每页条数。
/// 默认 20。
pub const DEFAULT_PAGE_SIZE: u32 = 20;

/// 列表接口每页条数上限。超过则按下限截断而非报错。
/// 默认 50。
pub const MAX_PAGE_SIZE: u32 = 50;

/// 下单接口的用户级限流（W6 落地）。
/// 单位：次/分钟。默认 60。
pub const RATE_LIMIT_ORDER_PER_MINUTE: u32 = 60;

/// 支付回调接口的来源级限流（W6 落地）。回调可能被重放攻击，需独立限制。
/// 单位：次/分钟。默认 600。
pub const RATE_LIMIT_CALLBACK_PER_MINUTE: u32 = 600;
```

## 8. 端点契约

**通用说明**：以下所有端点均返回统一响应包体（§3），成功时 `code = 0`。

**每个端点都隐含下列「通用错误」**，端点小节里不再重复列出；除这些之外出现的错误码必须在对应端点的「错误」行中显式列出，未列出的不应出现。

| 通用错误 | 何时出现 | 例外 |
| --- | --- | --- |
| `500 INTERNAL_ERROR` | 任何未预期异常 | 无 |
| `503 SERVICE_UNAVAILABLE` | Postgres / Redis 不可达、优雅停机中 | 无 |
| `401 UNAUTHORIZED` | 缺 token 或 token 无效/过期 | 回调端点改为 `401 INVALID_SIGNATURE`（验签） |
| `403 FORBIDDEN` | 访问他人资源、非管理员调 Admin 接口 | 回调端点不适用（无用户身份） |
| `429 RATE_LIMITED` | 触发限流（W6 落地） | 无 |

### 8.1 订单（用户侧）

#### `POST /orders` —— 下单

| 项 | 内容 |
| --- | --- |
| 认证 | 必须（`user_id` 取自 token） |
| 请求头 | `Idempotency-Key: <uuid>` **必填**；缺失返回 `400 VALIDATION_ERROR` |
| 幂等 | **同一 key + 同一请求体 → 回放首次响应**（含原 `order_id`，HTTP 200）；同一 key + 不同请求体 → `409 IDEMPOTENCY_KEY_REUSED`；首次仍在处理 → `409 IDEMPOTENCY_IN_PROGRESS`（可重试） |
| 成功 | `201 Created` |
| 错误 | 端点特有：`400 VALIDATION_ERROR`（含**缺失 `Idempotency-Key`**）、`404 PRODUCT_NOT_FOUND`、`409 STOCK_INSUFFICIENT`、`409 PRODUCT_OFF_SALE`、`409 IDEMPOTENCY_KEY_REUSED`、`409 IDEMPOTENCY_IN_PROGRESS` |

请求：

```json
{
  "items": [
    { "product_id": 1001, "quantity": 2 }
  ]
}
```

```json
// 幂等命中时回放首次响应，HTTP 200 而非 201
{
  "code": 0,
  "message": "ok",
  "data": {
    "order_id": "01932f4e-8a1b-7c3d-9e2f-1a2b3c4d5e6f",
    "status": "PENDING_PAYMENT",
    "total_amount": 25900,
    "expires_at": "2025-03-12T09:00:00Z",
    "items": [
      { "product_id": 1001, "quantity": 2, "unit_price": 12950, "subtotal": 25900 }
    ],
    "created_at": "2025-03-12T08:30:00Z"
  },
  "request_id": "..."
}
```

> **响应里的 `items` 是服务端价格快照**，与请求无关 —— 客户端传的价格一律忽略（用例 1 第 4 步）。

#### `GET /orders` —— 我的订单列表

| 项 | 内容 |
| --- | --- |
| 查询参数 | `status`（可选，多值逗号分隔）、`page`、`page_size`、`sort` |
| 成功 | `200 OK`，`data` 为数组，`meta` 带分页信息 |
| 错误 | 端点特有：无。`page_size > MAX_PAGE_SIZE` 时**截断而非报错**；`status` 传了非法枚举值才返回 `400 VALIDATION_ERROR` |

#### `GET /orders/{id}` —— 订单详情

| 项 | 内容 |
| --- | --- |
| 成功 | `200 OK`。`data` 含 `status` / `total_amount` / `expires_at` / `paid_at` / `shipped_at` / `delivered_at` / `refund_requested_at` 与逐项 `refund_status` |
| 错误 | 端点特有：`403 FORBIDDEN`（他人订单）、`404 ORDER_NOT_FOUND` |

> **越权与不存在的取舍**：`GET /orders/{id}` 对**他人的订单**返回 `403`，对**不存在的 ID** 返回 `404`。两者可区分是因为订单 ID 是 UUID，猜不到，不存在性泄露风险可接受；若要更严可统一返回 `404`。

#### `POST /orders/cancel/{id}` —— 取消未支付订单

| 项 | 内容 |
| --- | --- |
| 成功 | `200 OK`，`data.status = "CANCELLED"` |
| 副作用 | 归还库存（`reserved → available`，同一事务）、移出延迟队列 |
| 幂等 | 重复取消 → `409 ORDER_ALREADY_FINAL`（第二次不该报 500） |
| 错误 | 端点特有：`403 FORBIDDEN`、`404 ORDER_NOT_FOUND`、`409 ORDER_NOT_CANCELLABLE`（已付款及之后）、`409 ORDER_ALREADY_FINAL` |

#### `POST /orders/refund/{id}` —— 申请退款

| 项 | 内容 |
| --- | --- |
| 请求体 | `{ "reason": "用户备注，可选" }`；**不传退款项 = 整单退**（v1 只支持这种） |
| 成功 | **`202 Accepted`** —— 钱还没退，最终状态由支付方回调决定。`data.status = "REFUNDING"` |
| 副作用 | 按申请时订单状态分路：`PAID` → 立即归还库存；`SHIPPED` / `DELIVERED` / `COMPLETED` → **库存不动**，等退货入库 |
| 幂等 | 重复申请 → `409 REFUND_ALREADY_REQUESTED` |
| 错误 | 端点特有：`400 PARTIAL_REFUND_NOT_SUPPORTED`、`403 FORBIDDEN`、`404 ORDER_NOT_FOUND`、`409 ORDER_NOT_REFUNDABLE`（`PENDING_PAYMENT` / `CANCELLED`）、`409 REFUND_ALREADY_REQUESTED` |

```json
// POST /orders/refund/{id}  请求（字段可省，省略即整单退）
{ "reason": "不想要了" }

// 响应 202 Accepted —— 注意 code 仍为 0，异步结果靠轮询/推送
{
  "code": 0,
  "message": "ok",
  "data": {
    "refund_id": "01932f50-1c2d-7a3b-8c4d-5e6f7a8b9c0d",
    "order_id": "01932f4e-8a1b-7c3d-9e2f-1a2b3c4d5e6f",
    "status": "REFUNDING",
    "amount": 25900,
    "stock_action": "RELEASED_IMMEDIATELY"   // 或 "WAIT_RETURN"（发货后申请，货回仓才归还）
  },
  "request_id": "..."
}
```

#### `POST /orders/refund-revoke/{id}` —— 撤销退款申请

| 项 | 内容 |
| --- | --- |
| 成功 | `200 OK`，`data.status` 回到 `refund_from_status`（`PAID` 或 `SHIPPED`） |
| 副作用 | `PAID` 场景**反向预占**（`available → reserved`）；`SHIPPED` 场景库存不动 |
| 关键规则 | 钱已发出或货已到仓 → 拒绝；反向预占失败 → **整个操作回滚** |
| 错误 | 端点特有：`400 PARTIAL_REFUND_NOT_SUPPORTED`、`403 FORBIDDEN`、`404 ORDER_NOT_FOUND`、`409 REFUND_ALREADY_SENT`【人工#1】、`409 RETURN_ALREADY_RECEIVED`【人工】、`409 REFUND_NOT_REVOCABLE_SIGNED`【人工#8】、`409 REFUND_REVOKE_STOCK_UNAVAILABLE`【人工#7】、`409 REFUND_NOT_REVOCABLE` |

### 8.2 商品

#### `GET /products` —— 商品列表

| 项 | 内容 |
| --- | --- |
| 查询参数 | `page`、`page_size`、`on_sale_only`（默认 `true`） |
| 成功 | `200 OK`。每项含 `id` / `name` / `price`（分）/ `available`（可售数量，**只读**） |
| 错误 | 端点特有：`400 VALIDATION_ERROR`、`404 PRODUCT_NOT_FOUND` |

#### `GET /products/{id}` —— 商品详情

| 项 | 内容 |
| --- | --- |
| 成功 | `200 OK`。**只暴露 `available`**，不返回 `reserved` / `in_transit` / `damaged` |
| 错误 | 端点特有：`404 PRODUCT_NOT_FOUND` |

> **为什么只暴露 `available`**：`reserved` / `in_transit` / `damaged` 是内部库存口径，暴露它们等于把经营数据给前端。前端只需要「能不能买、还剩几件」。

### 8.3 支付

#### `POST /payments/pay/{order_id}` —— 发起支付

| 项 | 内容 |
| --- | --- |
| 前置 | 订单状态必须为 `PENDING_PAYMENT` 且未超时 |
| 成功 | `200 OK`，`data` 含支付方所需参数（如 `pay_url` 或 `prepay_id` + `nonce` + `sign`），由 `provider` 决定 |
| 幂等 | 允许重复调用（每次可返回新的一次性支付凭证），**不改变订单状态** |
| 错误 | 端点特有：`403 FORBIDDEN`、`404 ORDER_NOT_FOUND`、`409 ORDER_ALREADY_FINAL`（已取消）、`409 INVALID_STATE_TRANSITION`（已支付） |

#### `POST /payments/callback/{provider}` —— 支付方回调

| 项 | 内容 |
| --- | --- |
| 认证 | **不走 Bearer token**，靠请求体里的 `signature` 验签 |
| 请求体 | `{ event_id, order_id, result, amount, occurred_at, signature }`，`result ∈ {PAY_SUCCESS, PAY_FAILED, REFUND_SUCCESS}` |
| 幂等 | **以 `event_id` 为唯一键去重**（与下单的 `Idempotency-Key` 是两套独立机制） |
| 成功 | **`200 OK` + 支付方要求的响应体**，包括「状态不匹配」的情况 |
| 失败 | **仅验签失败返回 `401 INVALID_SIGNATURE`**（也是唯一返回非 200 的情形）；其余一律 200，包括状态不匹配、订单不存在、金额不符 |
| 错误 | 端点特有：`401 INVALID_SIGNATURE`（不适用通用错误里的 401/403） |

> **两个必须记住的点**：
> 1. 重放 50 次只处理一次，其余返回 200（DoD #3）；
> 2. 已到达终态的订单收到回调，**返回 200 + 落 `payment_events.status = IGNORED`**，不对支付方报错（§4 规则 1）。

#### `POST /payments/mock-success/{order_id}` —— 开发环境模拟支付成功（可砍）

| 项 | 内容 |
| --- | --- |
| 用途 | 本地开发/压测时免去接真实支付方；内部走**同一条**回调处理链路，不另写一份 |
| 成功 | `200 OK`，`data.status = "PAID"`（并触发自动发货入队） |
| 限制 | **仅当 `APP_ENV != production` 时注册该路由**，生产环境应 404 |
| 错误 | 端点特有：`404 ORDER_NOT_FOUND`（含路由未注册时的 404）、`409 ORDER_ALREADY_FINAL` |

```json
// POST /payments/mock-success/{order_id} 响应
{
  "code": 0,
  "message": "ok",
  "data": {
    "order_id": "01932f4e-8a1b-7c3d-9e2f-1a2b3c4d5e6f",
    "status": "PAID",
    "paid_at": "2025-03-12T08:35:00Z",
    "auto_ship_at": "2025-03-12T08:40:00Z"   // = paid_at + AUTO_SHIP_DELAY_SECONDS
  },
  "request_id": "..."
}
```

回调端点（`POST /payments/callback/{provider}`）的响应体由 `provider` 的协议决定，本项目不自造包体，例如：

```json
// 微信/支付宝风格：只要 HTTP 200 且应答体匹配其约定即可
{ "code": "SUCCESS", "message": "OK" }
```

> **回调响应不带本项目统一包体** —— 它是给支付方看的，不是给前端看的。这条是 §3 的唯一例外。

### 8.4 管理与运维

| 端点 | 说明 | 成功 | 端点特有错误（通用错误另计） |
| --- | --- | --- | --- |
| `POST /admin/orders/ship/{id}` | 手动发货，走与自动任务**同一个**服务方法 | `200`，`status=SHIPPED` | `403 FORBIDDEN`、`404 ORDER_NOT_FOUND`、`409 INVALID_STATE_TRANSITION`（非 `PAID`） |
| `POST /admin/orders/deliver/{id}` | 手动签收，走与自动任务**同一个**服务方法 | `200`，`status=DELIVERED` | `403 FORBIDDEN`、`404 ORDER_NOT_FOUND`、`409 INVALID_STATE_TRANSITION`（非 `SHIPPED`） |
| `POST /admin/orders/return-received/{id}` | 手动确认退货包裹入库 | `200`，`status` 依到位情况为 `REFUNDED` 或 `PARTIALLY_REFUNDED` | `403 FORBIDDEN`、`404 ORDER_NOT_FOUND`、`409 INVALID_STATE_TRANSITION` |
| `GET /admin/orders` | 按状态筛选订单，`REFUNDING` 队列靠它 | `200`，分页 | `403 FORBIDDEN` |
| `GET /healthz` | 存活探测（D6 实现） | `200`，`data` 含 `db` / `redis` 连通性 | 无（依赖不可用直接 `503 SERVICE_UNAVAILABLE`，即通用错误） |

> **管理端点的共同纪律**：手动路径与自动路径必须调用**同一个服务方法**，否则幂等与库存语义会分叉（`01-usecases.md` 用例 4 的硬要求）。`GET /admin/orders` 是**唯一能看到全部内部库存字段与 `IGNORED` 事件**的入口，也是【需人工介入】场景的排查面板。

## 9. 契约的机器可读形态（DoD #5）

| 产物 | 来源 | 时机 |
| --- | --- | --- |
| OpenAPI 3.1 JSON | `utoipa` 从 handler 的 `#[utoipa::path]` + DTO 的 `#[derive(ToSchema)]` 生成 | W3 |
| 静态 `openapi.json` | 构建期导出到 `docs/openapi.json` 并入库，便于 diff 审查 | W3 |
| 前端 TS 类型 | `openapi-typescript` 从 `openapi.json` 生成到 `web/src/types/api.d.ts` | W3 |
| 契约一致性检查 | CI 里重新生成 openapi.json，若与入库版本不一致则失败 | W9 |

**`///` 注释与 OpenAPI 的关系**：`utoipa` 会把字段与枚举变体上的 `///` 直接写进 schema 的 `description`。所以本文档的 `///` 纪律不是额外负担，而是**OpenAPI 文档的质量来源** —— 没有它，生成的文档只有类型没有语义，前端还是得回来问人。

## 10. 交给 D4 的输入

1. **表字段草案**要能承载本文所有错误码的判定依据。`orders` 表至少需这些「判定用」列（除常规字段外）：
   - 状态与时间：`status`、`expires_at`、`paid_at`、`auto_ship_at`、`shipped_at`、`expected_delivered_at`、`delivered_at`、`completed_at`、`refund_requested_at`、`cancelled_at`、`cancel_reason`
   - 退款判定：`order_items.refund_from_status`（**撤销必需**）、`refund_status`（含 `REVOKED`）、`refund_shipped_at`、`return_received_at`、`return_condition`
   - 支付与事件：`refunds.status`（含 `SENT` 与 `REVOKED`）、`refunds.attempt_count`、`payment_events.status`（含 `IGNORED` / `AMOUNT_MISMATCH` / `UNKNOWN_ORDER`）
2. **常量落到配置结构体**：§7 的每个常量在 `config.rs` 里既要有 `///`，也要有对应的环境变量名（如 `ORDER_TIMEOUT_MINUTES` ← `ORDER_TIMEOUT`）。
3. **金额类型定死**：数据库用 `BIGINT`（分），Rust 用 `i64`，**不用 `DECIMAL` 与浮点**，避免三处精度不一致。
   - **金额不变量**：`orders.total_amount = Σ order_items.subtotal`，且 `order_items.subtotal = unit_price × quantity`。这是对账基线的一部分，D4 写表时要能表达。
   - 未来若加优惠券/折扣，**不能改写 `total_amount` 的语义**，要另加 `discount_amount` / `payable_amount` 字段；退款金额以 `payable_amount` 为准。
4. **待定**：错误码的数字区间是否要在 D4 一并定成表（枚举），还是仅作为代码常量 —— 建议仅代码常量，不入库。
