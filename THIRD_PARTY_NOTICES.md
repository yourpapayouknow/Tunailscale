# 第三方声明

Tunailscale是独立项目，不是Tailscale官方客户端，也不代表上游项目背书。

本发行包包含以下组件及其依赖：

- Tailscale：固定上游提交`b83f28ebfbd9f86c2543e30e9dcf035a417dce1e`，应用`patches/`中的iOS原生路由及DNS适配补丁。上游代码采用BSD-3-Clause许可，详见`licenses/tailscale.com/LICENSE`。
- Go：构建工具链为Go1.27.3，标准库版权及许可见`licenses/go/LICENSE`。
- Go第三方依赖：按iOS/arm64及实际构建标签，由go-licenses v2.0.1收集对应许可证、版权声明及需分发材料，位于`licenses/`各组件目录。

本声明与完整`licenses/`目录同时包含在源码和安装包中。未单独声明许可的本项目代码保留所有权利；第三方组件继续适用各自的许可证。
