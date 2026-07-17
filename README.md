# Apple Music Bar

一个只驻留在 macOS 菜单栏的 Apple Music 同步歌词应用。没有 Dock 图标，也不会创建常驻窗口。

## 功能

- 读取 Apple Music 当前曲目与播放进度
- 优先显示 LRC 时间轴歌词
- 精确匹配失败时自动尝试简繁体标题和宽松搜索
- 状态栏逐句同步，长歌词自动滚动
- 点击状态栏歌词可查看紧凑的专辑封面与曲目信息，并控制上一首、播放/暂停和下一首
- 通过 MusicKit 读取用户资料库；点击播放器上方的播放列表名称可展开封面轮播，支持触控板双指左右切换
- 选择播放列表后在播放器下方显示可滚动歌曲列表；歌单自身没有封面时自动使用首个有封面的歌曲封面作为兜底
- 支持跟随系统、简体中文、English 和繁體中文界面
- 未匹配到同步歌词时，按歌曲时长估算普通歌词进度
- 菜单中可手动重新匹配当前歌曲的歌词
- Apple Music 未启动时保持安静驻留

## 构建与运行

需要 macOS 14 或更高版本，以及 Xcode / Xcode Command Line Tools。

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open dist/AppleMusicBar.app
```

第一次读取播放信息时，macOS 会询问是否允许 Apple Music Bar 控制“音乐”。请选择“允许”。如果曾经拒绝，可前往：

> 系统设置 → 隐私与安全性 → 自动化 → Apple Music Bar → 音乐

运行测试：

```bash
swift test
```

可选的 LRCLIB 在线匹配测试：

```bash
APPLE_MUSIC_BAR_INTEGRATION_TESTS=1 swift test --filter LyricsRepositoryIntegrationTests
```

## MusicKit 配置

资料库和播放列表封面使用 MusicKit。需要在 Apple Developer 后台为显式 App ID 启用 MusicKit App Service，并确保签名应用的 Bundle ID 与该 App ID 完全一致。

```bash
APPLE_MUSIC_BAR_BUNDLE_ID=com.example.AppleMusicBar \
APPLE_MUSIC_BAR_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
./scripts/build-app.sh
```

未提供以上环境变量时仍会生成临时签名应用，可用于测试菜单和歌词功能，但 MusicKit 无法为未注册的 Bundle ID 自动生成开发者令牌。

GitHub Release 要启用 MusicKit，需要配置以下 Actions secrets：

- `MUSICKIT_BUNDLE_ID`
- `DEVELOPER_ID_CERTIFICATE_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `BUILD_KEYCHAIN_PASSWORD`

## 发布

推送 `v*` tag 后，[Release workflow](.github/workflows/release.yml) 会在 GitHub 的 macOS runner 上运行测试、构建 arm64+x86_64 通用应用、打包 DMG、生成 SHA-256 校验文件并创建 GitHub Release。tag 必须与 `Resources/Info.plist` 中的版本一致。

```bash
git push origin main --tags
```

也可以在 GitHub Actions 页面手动运行工作流并填写已经存在的 tag；这适合补发旧版本。

## 歌词来源与隐私

应用先检查曲目内嵌的时间轴歌词，再请求 [LRCLIB](https://lrclib.net)。在线匹配只会发送歌名、歌手、专辑和曲目时长；不会读取或上传 Apple ID、资料库、播放历史或任何账号令牌。

Apple Music 自带的目录歌词没有公开的桌面端逐行读取接口，因此在线歌曲不一定能直接取得 Apple 官方歌词。LRCLIB 匹配失败时，应用会回退到曲目内嵌歌词；两者都没有时显示歌名与歌手。
