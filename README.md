# Plain Craft Launcher (PCL) 非官方社区修改版

> 本项目是第三方基于 Plain Craft Launcher 独立制作的非官方修改项目，与 PCL 官方无隶属、授权或合作关系。

## 原项目与署名

- 原项目： [Plain Craft Launcher](https://github.com/Meloong-Git/PCL)
- 原作者：龙腾猫跃（LTCat）
- 支持原作者： [爱发电赞助入口](https://meloong.com/afd/a/LTCat)
- 原项目许可与合理使用指南：见仓库中的 [LICENCE](LICENCE)

## 这个仓库是什么

本仓库只公开“PCL2社区版”品牌调整工具及说明，当前目标版本为 PCL 2.99.0.0。工具只调整：

- 主窗口标题与左上角显示名；
- “关于与鸣谢”中的产品显示名；
- Windows 文件属性中的产品名与文件描述；
- 单例窗口查找所需的对应标题；
- 默认标题栏 Logo 类型和文字。

内部程序集名、PCL 配置目录、版本号、资源包和非白名单方法保持不变。工具会要求输入文件 SHA-256，并在写出后比较所有非目标方法、字段、资源和程序集引用。

## 明确不包含

本仓库不提供或上传：

- PCL 可执行文件、用户配置、账号数据或私密密钥；
- 主题、赞助内容或付费功能的解锁代码；
- 绕过下载限制或网络限制的代码；
- 任何声称来自 PCL 官方的构建。

公开构建与分发时应继续遵守原项目指南，包括明确标注第三方身份、保留原作者署名和赞助链接、公开源代码，并保持 Windows 版本的主要色相为蓝色。

## 使用方法

需要 Windows、PowerShell 7，以及 Mono.Cecil 0.11.6 的 `Mono.Cecil.dll`。只应处理你合法取得且已自行备份的 PCL 2.99.0.0 文件。

```powershell
$input = 'D:\你的目录\Plain Craft Launcher 2.exe'
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $input).Hash

pwsh .\scripts\Invoke-Pcl2CommunityBrandPatch.ps1 `
  -InputExe $input `
  -OutputExe '.\artifacts\PCL2社区版.exe' `
  -ExpectedInputSha256 $hash `
  -CecilPath 'C:\路径\Mono.Cecil.dll' `
  -ReportJson '.\artifacts\branding-patch-report.json'
```

输出文件必须先在隔离目录测试。确认窗口标题、左上角显示名、关于页、文件属性和第二实例唤回均正常后，再手动替换；替换前务必备份原文件和配置。

## 支持范围

此工具对程序集结构有严格断言，目前只支持 2.99.0.0。其他版本会停止并报错，不会尝试模糊修改。
