# Vectra

桌面磁贴小组件（MacroSTAR Studio）· Flutter + Win32 版

## 构建

```
flutter build windows --release --no-pub
```

产物：`build\windows\x64\runner\Release\vectra.exe`（连同 DLL 与 `data\` 一起分发）。

打发布包（Release 文件夹 + 便携版，不再出安装版）：

```
tool\build_release.bat
```

产物：
- `build\windows\x64\runner\Release\`（整个文件夹就是发布版，解压即用）
- `installer\out\Vectra-<版本号>-便携版.exe`

## 版本号

唯一出处是 `pubspec.yaml` 的 `version:`。那里写 `A.B.C+D`，在 Windows 上就是
四段版本 `A.B.C.D`——exe 的文件版本、便携版包名、关于页、插件请求的
User-Agent 全部由它派生，**不要在别处再写死一份**。

当前基准 `0.1.1.120`。规矩：每加一个 git 节点，最后一段 +2。

```
0.1.1.120  ->  0.1.1.122  ->  0.1.1.124
```

也就是每次提交前把 `pubspec.yaml` 改成：

```yaml
version: 0.1.1+122
```

## 测试

```
flutter test --no-pub
node test/js/lrc_verify.js   # 歌词解析纯函数验证
```
