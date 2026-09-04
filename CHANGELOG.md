# 更新日志

本项目的脚本更新与重要修复记录在这里。运行 `cx update-script` 后，终端也会显示当前版本的更新提示。

## 2026.09.04.1 — 2026-09-04

### 新增

- 脚本安装或更新完成后显示版本号、发布日期和本次更新内容。
- 新增仓库更新日志，方便查看历史修改。

### 修复

- 修复基元律动 Responses 请求自动携带 `web_search` 时出现 `RESPONSES_FEATURE_NOT_SUPPORTED` 的问题。
- 选择、切换或更新已有基元律动配置时，自动设置 `web_search = "disabled"`。
- GitHub Actions 补充 `tomlkit` 测试依赖。
