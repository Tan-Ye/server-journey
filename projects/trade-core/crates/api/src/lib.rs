//! trade-core HTTP 层。
//!
//! 暴露 `router()` 供集成测试直接构建路由，无需启动真实进程。

/// 构建应用路由。
///
/// 目前只有 `GET /healthz`，其余端点在 W2 起逐步加入。
pub fn router() -> axum::Router {
    axum::Router::new()
}