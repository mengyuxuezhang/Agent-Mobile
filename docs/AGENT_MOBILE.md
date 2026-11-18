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

配置品牌项目和 API 后，可在首次设置或「设置 → 羽枢账号」使用桌面端账号登录。页面读取同一会员、积分余额、最近积分流水和授权模型。启动本机 DSH 后，选择「连接羽枢模型到本机引擎」，回到聊天并在模型列表选择 YushuHub 下的文本模型。

模型适配位于 `app/lib/managed/`，沿用上游自定义 provider 接口。应用进程将获授权的模型请求转发至同一个 YushuHub 项目的模型网关。DSH 持有本次启动的本地连接密钥，用户令牌仅存在于应用进程中。模型用量和账务以 YushuHub 记录为准，应用不会本地预扣或自动重发。退出账号立即关闭转发并尝试清理本机 provider。

运行 `dart run tool/managed/verify_model_gateway.dart`（工作目录 `app/`）可验证环回 HTTP 转发、授权模型拦截、流式用量和积分不足响应。Android 模拟器使用 x64 flavor 和同源 x86_64 DSH 运行时。首次后台联调先核对会员、余额和模型，发送一条短消息后刷新积分流水，对照桌面端同账号记录。贴牌打包和桌面下载入口在该闭环通过后接入。

对外提供 APK 时，在同一下载页提供该版本的对应源码与构建说明，保留版权、许可和变更声明。签名凭据、供应商密钥和用户会话保存在各自的运行环境。
