# ROADMAP · Rust 后端 12 周

## 0. 背景与已定决策

- 起点：前端转后端；Rust 基础语法已熟悉；已跟写完 person-blog-system（大致了解后端 server 的分层与代码逻辑），该项目**不再作为主线**。
- 主线项目：`projects/trade-core`（Rust · Axum · SQLx · PostgreSQL · Redis · Docker · Nginx · Prometheus）。
- 时间预算：**21 h/周**（周一~周五 3h/天，周六 5h，周日 1h 复盘）。
- 总周期：**12 周**（10 周内容 + 2 周缓冲）。

## 1. 总目标

用 Rust 从零构建一个具备生产形态的交易内核：涵盖商品、库存、订单、支付回调、超时取消与对账；在真实并发压力下保证不超卖、不重复下单、回调幂等；并且可部署、可观测、可恢复。

### 验收标准（DoD）

| # | 标准 | 验证方式 |
| --- | --- | --- |
| 1 | 不超卖 | 库存 = 100，1000 并发下单，成功恰好 100 笔，无负库存，脚本可复现 |
| 2 | 下单幂等 | 同一 Idempotency-Key 重发 100 次，只产生 1 笔订单 |
| 3 | 回调幂等 | 同一支付回调重放 50 次，状态只流转一次；乱序/延迟回调不破坏状态机 |
| 4 | 超时取消 | 未支付订单 30 分钟内自动取消并归还库存；服务重启后任务不丢 |
| 5 | 契约完整 | 全部接口有 OpenAPI 文档，前端 TS 类型自动生成 |
| 6 | 可上线 | 一条命令部署到云服务器，HTTPS 可访问 |
| 7 | 可观测 | Prometheus 看到 QPS / P99 / 下单成功率 / 扣减冲突率 |
| 8 | 可恢复 | 完成一次数据库备份 + 恢复演练并记录耗时 |
| 9 | 有沉淀 | 12 篇周复盘 + 各阶段笔记 + 架构文档 + 压测报告 |

## 2. 12 周计划

| 周 | 覆盖阶段 | 目标 | 交付物 |
| --- | --- | --- | --- |
| W1 | 0 + 1① | 领域建模、契约、环境、骨架 | 用例/状态机/契约/DoD + 跑通骨架 + 统一错误层 |
| W2 | 1② + 2① | 并发原语、tokio、async 本质；Axum 基础 | 服务骨架定稿 + 商品/购物车 CRUD |
| W3 | 2② + 3① | OpenAPI/TS 类型/幂等中间件；SQLx 接入 | 接口文档 + 迁移脚本 |
| W4 | 3② + 3③ | 建模、索引、事务、扣减方案 | 下单主链路跑通 |
| W5 | 4①② | 鉴权 + 授权 + 安全 | 鉴权模块 +《前端侧安全清单》 |
| W6 | 5①② | 缓存与一致性；分布式锁与限流 | 缓存层 + 限流中间件 |
| W7 | 5③ + 6① | 延迟队列、回调幂等；指标与日志 | 超时取消 + 回调幂等达成 + 指标看板 |
| W8 | 6② + 7① | 秒杀压测与优化；部署上线 | 压测报告 + 线上可访问 |
| W9 | 7② + 8① | CI/CD、备份演练；分布式设计 | 备份恢复演练记录 + 架构设计文档 |
| W10 | 8② + 收尾 | 拆库存服务、对账、文档 | DoD #1–#9 全部达成 |
| W11 | 缓冲 | 补欠账、返工 | — |
| W12 | 收尾 | 作品集打磨、总复盘 | 可展示的完整项目 |

**每日节奏**：前 15 min 回顾「昨日第一步」+ 锁定今日目标 → 中间 2h15 推进 → 最后 30 min 提交、写日志、写「明日第一步」。周六 5h 拆成 2.5h + 2.5h。

## 3. W1 逐日计划

| 天 | 时长 | 阶段 | 目标 | 产出物 |
| --- | --- | --- | --- | --- |
| D1 | 3h | 0 | 三条核心用例完整流程（下单/回调/超时取消） | `docs/01-usecases.md` |
| D2 | 3h | 0 | 订单状态机：转移表 + 触发者 + 前置条件 + Mermaid 图 | `docs/state-machine.md` |
| D3 | 3h | 0 | 8–12 个端点 API 契约 + 统一错误码规范 | `docs/02-api-contract.md` |
| D4 | 3h | 0 | DoD 清单 + 难点初步方案假设 + 表字段草案 | `docs/03-dod.md` |
| D5 | 3h | 0 | 环境就绪：Docker Postgres+Redis、sqlx-cli、工具链、git init | `docker-compose.yml` |
| D6 | 5h | 0→1① | 三 crate 骨架 + tracing + `GET /healthz`；随后重写错误层 | 首次 commit + 错误层雏形 |
| D7 | 1h | — | 复盘 W1，敲定 W2 逐日 | `journal/W01.md` |

## 4. 每日 / 每周机制

**目标写法必须可验证**：

- ❌「学习 Axum 中间件」
- ✅「写出给所有响应加 X-Request-Id 的中间件，并用 curl 验证」

**每日记录模板**（写入 `journal/W{周}.md`）：

```markdown
### D3 · 03-12
目标：
实际耗时：
产出物：（文件 / commit）
卡点：（超过 2h 未解的记下并跳过，周末集中处理）
明日第一步：（收工立刻写）
```

**周日复盘三问**：

1. 这周哪个判断被推翻了？
2. 卡点是知识缺口还是环境问题？
3. 下周哪天最容易断，提前把任务调轻？

## 5. 风险与应对

| 风险 | 应对 |
| --- | --- |
| Rust async + Axum 上手慢 | W2–W3 只写玩具 demo，不碰业务；单点卡超 2h 记录跳过 |
| 领域建模返工 | W4 之前不写业务逻辑，先把骨架和契约钉死 |
| 时间被打断 | 周六是补课日，W11 是缓冲周，欠账不往下滚 |
| 追求压测数字跑偏 | 本地 Docker 压测即可，目标是证明正确性（不超卖），不是刷 QPS |
| 只看不写 | 每天必须留下 commit 或笔记文件，否则不算完成 |

## 6. 目录结构

### server-journey/

```text
server-journey/
├── README.md                 # 仓库说明 + 目录索引 + 进度看板
├── ROADMAP.md                # 总路线 + 12 周计划 + DoD + 风险
├── journal/                  # 周复盘 W01.md ...
├── notes/                    # 00-mindset 01-rust-server 02-axum-api 03-database
│                             # 04-auth-security 05-cache-async 06-observability
│                             # 07-deploy 08-distributed
├── reading/                  # 源码阅读笔记（meilisearch / lemmy / loco / sqlx）
└── projects/
    └── trade-core/           # 主线项目，代码自己写；当前为纯空目录
```

### trade-core/（仅设计，暂不创建）

```text
trade-core/
├── Cargo.toml · rust-toolchain.toml · rustfmt.toml · clippy.toml · .editorconfig
├── .env.example · .gitignore · README.md · justfile
├── docker-compose.yml · docker-compose.observability.yml · Dockerfile
├── crates/
│   ├── api/            # HTTP 层：main.rs · router.rs · state.rs · error.rs · openapi.rs
│   │                   # middleware/(request-id·幂等键·限流·鉴权·tracing)
│   │                   # handlers/(product·cart·order·payment·admin) · dto/
│   ├── domain/         # 纯业务：不依赖 axum / sqlx，可脱环境单测
│   │                   # model/ · state_machine/ · service/ · port.rs · error.rs
│   └── infra/          # db/ · cache/ · queue/ · payment/ · config.rs
├── migrations/         # sqlx 迁移 0001_init.sql ...
├── tests/              # common/mod.rs · order_flow.rs · idempotency.rs · stock_concurrency.rs
├── benches/k6/         # seckill.js · order_flow.js
├── docs/               # 01-usecases · 02-api-contract · 03-dod · state-machine · architecture
│                       # reports/(压测报告·优化记录·备份恢复演练)
├── deploy/             # nginx/ · systemd/ · grafana/
├── .github/workflows/ci.yml
└── web/                # 可选，W8 之后：生成的 TS 类型 + 极简下单页
```

**结构设计理由（三条）**：

1. 只有三个 crate，依赖方向 `api → domain ← infra`。domain 不依赖 Axum 与 SQLx，「库存够不够、状态能不能转移」可做纯单测；`port.rs` 放 repository trait，infra 实现，依赖倒置。
2. 订单状态机单独成模块且是唯一真相源，合法转移只在一处定义。DoD #3 能否通过全看这里收口。
3. `docs/` 从第一天就建，D1–D4 只写文档不写代码——先定契约和状态机，再写实现。
