# 参与贡献

感谢你改进 PulseBoard。

## 开发流程

1. Fork 仓库并基于 `master` 创建功能分支。
2. 保持改动聚焦，并为数据处理逻辑补充测试。
3. 在提交前运行：

   ```bash
   swift test
   swift build -c release
   ```

4. 提交 Pull Request，说明问题、实现方式和验证结果。界面改动请附截图。

## 代码约定

- 最低支持 macOS 14，使用 Swift 6。
- 优先使用公开系统 API；使用非公开或机型相关的数据通道时，必须提供缺失值回退，并在文档中说明准确性边界。
- 不提交 `.build/`、`dist/`、SQLite 数据库、签名私钥或公证凭据。
- 新增采样器时避免阻塞主线程，并明确累计值到速率值的转换方式。

## 报告问题

普通缺陷和功能建议请使用 GitHub Issues。涉及可被利用的安全问题时，请不要公开 Issue，改按 [SECURITY.md](SECURITY.md) 报告。
