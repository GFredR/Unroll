#!/bin/bash
# ============================================================================
# make_fixtures.sh —— 重新生成 ArchiveKit 单测 fixture(设计文档 §6.2)
# ----------------------------------------------------------------------------
# 造法与设计文档 §5.9 的 POC 完全一致,产物全部入库(每个仅几百字节):
#   plain.cbz              明文 zip:3 图 + note.txt + .DS_Store + __MACOSX/(验证过滤与自然排序)
#   partial.cbz            部分加密:page1/2 明文 + page3/4 ZipCrypto(§5.9 表「部分加密」)
#   encrypted-zip.cbz      全加密 ZipCrypto(zip -P)
#   encrypted-zip-aes.cbz  全加密 AES-256(zip -Z aes256;本机 zip 不支持则跳过)
#   empty.cbz              0 条目(→ .empty)
#   no-images.cbz          只有 txt(→ .noImages)
#   corrupted.cbz          纯文本伪装(→ .corrupted)
#   plain.cbt              明文 tar(P0 格式补样本)
#   encrypted-content.cb7  7z 内容加密(可列目录、不可解;-mhe=off)
#   encrypted-header.cb7   7z 头部加密(列目录即 FATAL -30;-mhe=on)
# 源图 src/*.png 为 8×8 纯色 PNG(python 标准库生成,零依赖、内容确定)。
# 改动任何造法后:重跑本脚本 + 重新提交产物 + 同步修改对应断言。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# ---- 1. 源图:8×8 纯色 PNG(确定性内容,零第三方依赖) ----------------------
python3 - <<'PY'
import struct, zlib, os

def write_png(path, rgb):
    W = H = 8
    row = bytearray()
    for _ in range(H):
        row.append(0)  # PNG filter type: None
        for _ in range(W):
            row += bytes(rgb)

    def chunk(tag, data):
        payload = tag + data
        return (struct.pack('>I', len(data)) + payload +
                struct.pack('>I', zlib.crc32(payload) & 0xffffffff))

    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(bytes(row), 9)) +
           chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)

os.makedirs('src', exist_ok=True)
colors = {
    'page1.png':  (255, 0, 0),
    'page2.png':  (0, 255, 0),
    'page3.png':  (0, 0, 255),
    'page4.png':  (255, 255, 0),
    'page10.png': (255, 0, 255),
}
for name, rgb in colors.items():
    write_png(f'src/{name}', rgb)

with open('src/note.txt', 'w') as f:
    f.write('not an image\n')
print('📦 src/ 源图就绪')
PY

# ---- 2. 清理旧产物 --------------------------------------------------------
rm -f plain.cbz mac-junk.cbz partial.cbz encrypted-zip.cbz encrypted-zip-aes.cbz \
      empty.cbz no-images.cbz corrupted.cbz plain.cbt \
      encrypted-content.cb7 encrypted-header.cb7
rm -rf staging
mkdir staging

# ---- 3. 明文 cbz(含干扰条目:验证过滤 + 自然排序) ------------------------
# 注意写入顺序故意乱序(page10, page2, page1):原始顺序 ≠ 自然顺序,
# 单测据此才能真正验证排序与 rawPosition 映射,而不是「碰巧有序」。
# ⚠️ 不要往 __MACOSX/ 里塞普通文件(2026-09-10 实测):libarchive 会把
# __MACOSX/ 条目数据当 AppleDouble 元数据解析,非合法 AppleDouble 内容
# 直接 FATAL「Invalid header」整档不可读。合法 AppleDouble 见 mac-junk.cbz。
cp src/page1.png src/page2.png src/page10.png src/note.txt staging/
touch staging/.DS_Store                       # 隐藏文件:应被过滤
(
  cd staging
  zip -q -X ../plain.cbz page10.png page2.png page1.png note.txt .DS_Store
)

# ---- 3b. Finder 风格 cbz:合法 AppleDouble 元数据条目 ---------------------
# macOS 右键压缩产物的典型形态:__MACOSX/._xxx 是合法 AppleDouble。
# 实测:libarchive 自行解析并消化这类条目(列目录时根本不出现),
# 本 fixture 锁死该行为 —— 真实用户的 Finder 压缩包必须能正常打开。
(
  cd staging
  python3 - <<'PY'
import zipfile, struct

# 最小合法 AppleDouble:magic 0x00051607 + version + 16 字节填充 + 0 个 entry
apple_double = struct.pack('>II16sH', 0x00051607, 0x00020000, b'\x00' * 16, 0)

with zipfile.ZipFile('../mac-junk.cbz', 'w') as z:
    z.write('page1.png', 'page1.png')
    z.write('page2.png', 'page2.png')
    z.write('page10.png', 'page10.png')
    z.writestr('__MACOSX/._page1.png', apple_double)
print('📦 Finder 风格样本就绪')
PY
)

# ---- 4. 部分加密 cbz:先明文后密文(§6.2 fixture #5) ----------------------
(
  cd staging
  cp ../src/page3.png ../src/page4.png .
  zip -q -X ../partial.cbz page1.png page2.png
  zip -q -X -P secret ../partial.cbz page3.png page4.png
)

# ---- 5. 全加密 ZipCrypto cbz(§5.9 表第 2 行) -----------------------------
(
  cd staging
  zip -q -X -P secret ../encrypted-zip.cbz page1.png page2.png page10.png
)

# ---- 6. 全加密 AES-256 cbz(§5.9.1 注:ZipCrypto 之外需补的样本) ----------
# 本机 zip 3.0 不支持 -Z aes256,改用 pyzipper(WinZip AES-256 规范)
(
  cd staging
  PYTHONPATH=/tmp/unroll-py7zr python3 - <<'PY'
import pyzipper

with pyzipper.AESZipFile('../encrypted-zip-aes.cbz', 'w',
                         compression=pyzipper.ZIP_DEFLATED,
                         encryption=pyzipper.WZ_AES) as z:
    z.setpassword(b'secret')
    for p in ('page1.png', 'page2.png', 'page10.png'):
        z.write(p, p)
print('📦 AES-256 样本已生成')
PY
)

# ---- 7. 空归档 / 无图归档 / 损坏归档 --------------------------------------
python3 - <<'PY'
import zipfile

with zipfile.ZipFile('empty.cbz', 'w'):
    pass  # 合法但 0 条目

with zipfile.ZipFile('no-images.cbz', 'w') as z:
    z.write('src/note.txt', 'note.txt')

with open('corrupted.cbz', 'w') as f:
    f.write('This is definitely not an archive, just plain text.\n')
print('📦 空/无图/损坏样本就绪')
PY

# ---- 8. 明文 cbt(tar,P0 格式) -------------------------------------------
(
  cd staging
  tar cf ../plain.cbt page1.png page2.png page10.png note.txt
)

# ---- 9+10. 7z 双形态加密(设计文档 POC 同款造法:py7zr) --------------------
# 本机无可用 7z CLI(坏包装脚本),改用 py7zr(POC 时就是它):
#   encrypted-content.cb7  内容加密(password + header_encryption=False → 可列目录不可解)
#   encrypted-header.cb7   头部加密(password + header_encryption=True  → 列目录即 FATAL)
# py7zr 装在隔离目录 /tmp/unroll-py7zr(pip --target,不污染任何环境)。
(
  cd staging
  PYTHONPATH=/tmp/unroll-py7zr python3 - <<'PY'
import py7zr

pages = ['page1.png', 'page2.png', 'page10.png']

# 注意:staging 里还有部分加密步骤的 page3/4 与垃圾文件,显式写、不 writeall
for target in ('../encrypted-content.cb7', '../encrypted-header.cb7'):
    header_encrypted = target.endswith('header.cb7')
    with py7zr.SevenZipFile(target, 'w',
                            password='secret',
                            header_encryption=header_encrypted) as z:
        for p in pages:
            z.write(p, p)
print('📦 7z 双形态加密样本就绪')
PY
)

rm -rf staging

echo "✅ fixture 全部生成完毕:"
ls -l *.cbz *.cbt *.cb7
