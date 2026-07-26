# Apple Music Bar

Apple Music Bar 是一个安静待在 macOS 菜单栏里的 Apple Music 同步歌词小工具。播放音乐时，它把当前歌词显示在菜单栏；点开后可以看封面、控制播放、浏览播放列表和歌曲。

## 适合谁

- 想边工作边瞄一眼 Apple Music 当前歌词的人
- 不想让歌词窗口占用桌面空间的人
- 希望菜单栏里顺手控制上一首、播放/暂停、下一首的人
- 想快速切换资料库播放列表和歌曲的人

## 主要功能

- 在菜单栏逐句显示 Apple Music 当前歌词，长歌词会自动滚动
- 点开菜单栏即可查看封面、歌曲信息、播放进度和控制按钮
- 支持上一首、播放/暂停、下一首和进度跳转
- 可展开 Apple Music 资料库播放列表，并查看垂直歌曲列表或横向封面列表
- 支持显示同步歌词面板，也可手动重新匹配当前歌曲歌词
- 优先使用曲目内嵌时间轴歌词，失败后请求 LRCLIB 在线匹配
- 匹配失败时会尝试简繁体标题转换和宽松搜索
- 没有同步歌词时，会按歌曲时长估算普通歌词进度
- 支持跟随系统、简体中文、English 和繁體中文界面
- Apple Music 未启动时保持安静驻留，不创建 Dock 图标或常驻窗口

## 安装与运行

目前可以从源码构建应用。你需要：

- macOS 14 或更高版本
- Xcode 或 Xcode Command Line Tools

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open dist/AppleMusicBar.app
```

第一次读取播放信息时，macOS 会询问是否允许 Apple Music Bar 控制“音乐”。请选择“允许”。

如果之前点过拒绝，可以在这里重新开启：

> 系统设置 -> 隐私与安全性 -> 自动化 -> Apple Music Bar -> 音乐

## 使用方式

1. 打开 Apple Music 并播放任意歌曲。
2. 启动 Apple Music Bar。
3. 在菜单栏查看当前歌词。
4. 点击菜单栏歌词打开迷你播放器。
5. 在播放器里控制播放、切换播放列表、展开歌曲列表或查看歌词面板。

如果菜单栏显示需要权限、没有歌曲或 Apple Music 未运行，按提示处理即可；应用不会在后台上传你的账号信息。

## 歌词来源与隐私

Apple Music Bar 会先检查曲目内嵌的时间轴歌词，再请求 [LRCLIB](https://lrclib.net) 匹配歌词。

在线匹配只会发送歌名、歌手、专辑和曲目时长；不会读取或上传 Apple ID、资料库、播放历史或任何账号令牌。

Apple Music 自带的目录歌词没有公开的桌面端逐行读取接口，因此在线歌曲不一定能直接取得 Apple 官方歌词。LRCLIB 匹配失败时，应用会回退到曲目内嵌歌词；两者都没有时显示歌名与歌手。

## 开发

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

## License

Apple Music Bar is released under the [MIT License](LICENSE).
