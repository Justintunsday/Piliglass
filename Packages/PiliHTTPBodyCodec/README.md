# PiliHTTPBodyCodec

未接入运行时的原生 body decoder 候选，与 HTTP transport、账户、UI 和播放器隔离。
没有默认 Cookie/认证、网络请求或存储。输入为已完整接收的 raw compressed body；
解压输出必须显式传入预算，超出预算不会返回截断成功。

`PiliHTTPBodyDecoder.decode(body:headers:maximumOutputBytes:)` 保留
`Request.responseBytesDecoder` 的首个 `content-encoding` 值及精确 `gzip`/`br`
匹配；其他 token 原样返回 bytes。Header 字典使用 Dio 已标准化的小写键；
raw HTTP transport 的有序 headers 转换由外部 client 负责。

gzip 使用系统 zlib，接受 Dart IO `GZipCodec` 已有 gzip/zlib envelope 和连接
member 行为。与旧 `decodeBytes` 一样，数据截断可能返回已经解出的部分 bytes；
没有声称整个压缩包已通过完整性验证。CRC 错误和尾随坏数据仍报错。
Brotli 使用 [Brotli 1.2.0 SwiftPM C 产品](https://github.com/EvgenijLutz/Brotli/tree/1.2.0)，
固定 tag commit `66b204011861bebb3c066b9e892f95aec2b773ce`，只链接
`libbrotlidec` / `libbrotlicommon` 的 device、simulator、macOS slice。
上游 [MIT license 与第三方 notices](https://github.com/EvgenijLutz/Brotli/tree/1.2.0/Third-Party%20Notices/brotli)
由 SwiftPM dependency 保留，仓库没有复制 decoder 源码或 encoder。

`utf8AllowMalformed` 去除一次开头 UTF8 BOM，然后进行 malformed replacement。
对照使用实际 Dart VM 的 `utf8.decode(..., allowMalformed:true)` 产出，覆盖
全部 256 单字节、65,536 双字节、截断/overlong/surrogate/max-scalar/BOM 向量，
以及 2,048 组确定性混合输入；比较 UTF16 units，不以 Swift Unicode 规范等价掩盖差异。

macOS 完整工具链、Flutter pub dependencies 就绪后执行：

```sh
python3 tool/check_native_body_codec.py
```

该工具先运行实际 production Dart decoder/Dio fixture，随后运行 Swift 6 package
contracts；输出在 `build/native-body-codec-check/`。静态 source 检查不代表已编译，
只有实际 Actions 和完整 Runner 同 SHA 通过后才能记录本切片验收。
