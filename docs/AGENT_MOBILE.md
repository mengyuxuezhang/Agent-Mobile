# Agent Mobile 开发与交付

Agent Mobile 是 [dsh-Go](https://github.com/ccch1mneyyy/dsh-Go) 的 Android 衍生客户端，原作者为 ccch1mneyyy。手机端及纳入发行包的二开代码按 AGPL-3.0 提供，第三方组件遵照原许可，见 [LICENSE](../LICENSE) 和 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。

初始基线记录在 [UPSTREAM_REV](../UPSTREAM_REV)。原始上游历史包含另行授权的素材。升级时先在独立检出获取目标版本，再运行 `python tooling/import-android-upstream.py <archive.zip> <目标目录>` 生成筛选后的源码基线，比较两个筛选版本的差异，并将差异应用到产品分支。上游原始历史与排除素材保留在本地参考区。合入后更新基线提交并检查资源及实际 APK。二开业务代码位于 `app/lib/managed/`。宿主层只负责注册入口与平台配置。

当前仓库包含 Android 代码、其运行时和共享依赖。导入时排除了上游网站、分发服务、其他平台工程与上游发布工作流。素材排除范围包括上游品牌源图及生成图、Deepy 和鲸娘宠物源文件及生成包、鲸尾活动图、求星弹窗贴纸、带原品牌或吉祥物的展示图和测试图。首版使用中性应用图标与系统图标。素材条款见 [ASSETS.md](../ASSETS.md)。

开发 APK 使用上游匹配版本的 Flutter、JDK 17、Android SDK/NDK 与对应 ABI 的运行时。品牌构建使用下列参数：

| 参数 | 配置方式 |
| --- | --- |
| 产品名称 | `AGENT_APP_NAME` Dart define 与 `agentAppName` Gradle 属性 |
| Android 包名 | `agentApplicationId` Gradle 属性 |
| 后台业务项目 | `AGENT_PROJECT_ID` Dart define，使用对应桌面端的项目标识 |
| API 入口 | `AGENT_API_BASE_URL` Dart define，使用 HTTPS 的 YushuHub API 根地址，例如 `https://example.invalid/api/` |
| 更新地址 | `AGENT_UPDATE_FEED` Dart define，未配置时禁用远程版本源 |

配置项目和 API 后，在设置中进入「羽枢账号」。当前实现请求登录验证码，使用桌面账号登录，读取账号、会员、余额和模型目录，并可刷新或退出。该入口用于开发联调。DSH 引擎的模型调用及扣费、品牌资源生成、后台打包入口、桌面下载入口和真机验证仍需接通。

对外提供 APK 时，在同一下载页提供该版本的对应源码与构建说明，保留版权、许可和变更声明。签名凭据、供应商密钥和用户会话保存在各自的运行环境。
