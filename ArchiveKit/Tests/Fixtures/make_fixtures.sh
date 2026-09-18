#!/bin/bash
# ============================================================================
# make_fixtures.sh —— 重新生成 ArchiveKit 单测 fixture(设计文档 §6.2)
# ----------------------------------------------------------------------------
# 造法与设计文档 §5.9 的 POC 完全一致,产物全部入库(每个几百字节 ~ 几 KB):
#   plain.cbz              明文 zip:3 图 + note.txt + .DS_Store + __MACOSX/(验证过滤与自然排序)
#   partial.cbz            部分加密:page1/2 明文 + page3/4 ZipCrypto(§5.9 表「部分加密」)
#   encrypted-zip.cbz      全加密 ZipCrypto(zip -P)
#   encrypted-zip-aes.cbz  全加密 AES-256(WinZip 规范,pyzipper)
#   empty.cbz              0 条目(→ .empty)
#   no-images.cbz          只有 txt(→ .noImages)
#   corrupted.cbz          纯文本伪装(→ .corrupted)
#   damaged-page.cbz       目录完好、page2 负载被翻一字节(→ 完整性检查报 1 个坏页)
#   mac-junk.cbz           Finder 风格:3 图 + 合法 AppleDouble 的 __MACOSX/._page1.png
#   mixed-content.cbz      3 页在 vol01/ 下 + **嵌套** __MACOSX/page1.png + readme.txt
#                          + .DS_Store(→ 锁「非图片一概不入列表」的回归,含第二层垃圾目录)
#   many-entries.cbz       3 页 + 300 个零字节填充条目(→ 专测"列目录中途能被叫停",~32KB)
#   plain.cbt              明文 tar(P0 格式补样本)
#   encrypted-content.cb7  7z 内容加密(可列目录、不可解;-mhe=off)
#   encrypted-header.cb7   7z 头部加密(列目录即 FATAL -30;-mhe=on)
#
# 源图 src/*.png 为 240×320 纯色加标签页(python 标准库生成,零依赖、内容确定):
#   底色区分页序(红/绿/蓝/黄/洋红),页面印「TEST PAGE n · NOT A COMIC」。
#   2026-09-15 加标签的原因:纯色页在阅读器里放大后就是一整块纯色方块,
#   被误开时极像"渲染 bug / 红色报错占位",用户实际被唬住过一次
#   (双击了 Fixtures/plain.cbz,以为 App 出了故障)。加字后一眼可辨。
#   底色本身仍是断言依据:单测把 data(at:) 与 src/pageX.png 逐字节比对。
#
# 改动任何造法后:重跑本脚本 + 重新提交产物 + 同步修改对应断言。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# ---- 0. 依赖预检(先查再删:半途失败会留下「旧产物已删、新产物没生成」的残局) --
# 必需:zip + python3。可选:pyzipper / py7zr(AES-256 与两种 7z 加密样本)——
# 装在隔离目录(不污染任何环境),缺失则跳过对应样本并保留旧产物,其余照常生成。
PY_DEPS="${UNROLL_FIXTURE_PY_DEPS:-/tmp/unroll-py7zr}"
command -v zip >/dev/null || { echo "❌ 缺少 zip,无法生成明文样本"; exit 1; }
command -v python3 >/dev/null || { echo "❌ 缺少 python3,无法生成源图"; exit 1; }

have_py_dep() { PYTHONPATH="$PY_DEPS" python3 -c "import $1" 2>/dev/null; }
HAVE_PYZIPPER=no; HAVE_PY7ZR=no
have_py_dep pyzipper && HAVE_PYZIPPER=yes
have_py_dep py7zr && HAVE_PY7ZR=yes
if [ "$HAVE_PYZIPPER" = no ] || [ "$HAVE_PY7ZR" = no ]; then
  echo "⚠️  可选依赖缺失(pyzipper=$HAVE_PYZIPPER py7zr=$HAVE_PY7ZR)→ 对应加密样本跳过,旧产物保留"
  echo "    补装:python3 -m pip install --target \"$PY_DEPS\" pyzipper py7zr"
fi

# ---- 1. 源图:240×320 纯色 + 标签(python 标准库,确定性) ------------------
python3 - <<'PY'
import struct, zlib, os

W, H = 240, 320

# 5×7 点阵字体(仅含标签用到的字符;'#' = 实心像素)
FONT = {
    'A': ['.###.', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'],
    'C': ['.###.', '#...#', '#....', '#....', '#....', '#...#', '.###.'],
    'E': ['#####', '#....', '#....', '####.', '#....', '#....', '#####'],
    'F': ['#####', '#....', '#....', '####.', '#....', '#....', '#....'],
    'G': ['.###.', '#...#', '#....', '#.###', '#...#', '#...#', '.###.'],
    'I': ['#####', '..#..', '..#..', '..#..', '..#..', '..#..', '#####'],
    'M': ['#...#', '##.##', '#.#.#', '#...#', '#...#', '#...#', '#...#'],
    'N': ['#...#', '##..#', '#.#.#', '#..##', '#...#', '#...#', '#...#'],
    'O': ['.###.', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'],
    'P': ['####.', '#...#', '#...#', '####.', '#....', '#....', '#....'],
    'R': ['####.', '#...#', '#...#', '####.', '#.#..', '#..#.', '#...#'],
    'S': ['.####', '#....', '#....', '.###.', '....#', '....#', '####.'],
    'T': ['#####', '..#..', '..#..', '..#..', '..#..', '..#..', '..#..'],
    'U': ['#...#', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'],
    '0': ['.###.', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'],
    '1': ['..#..', '.##..', '..#..', '..#..', '..#..', '..#..', '.###.'],
    '2': ['.###.', '#...#', '....#', '...#.', '..#..', '.#...', '#####'],
    '3': ['####.', '....#', '....#', '.###.', '....#', '....#', '####.'],
    '4': ['#..#.', '#..#.', '#..#.', '#####', '...#.', '...#.', '...#.'],
    '5': ['#####', '#....', '#....', '####.', '....#', '#...#', '.###.'],
    ' ': ['.....', '.....', '.....', '.....', '.....', '.....', '.....'],
}


def render(rgb, lines):
    """lines: [(text, scale, top_y), ...],每行水平居中"""
    # 浅底色用黑字、深底色用白字:否则黄底白字会看不见
    luma = (rgb[0] * 299 + rgb[1] * 587 + rgb[2] * 114) // 1000
    ink = (0, 0, 0) if luma > 140 else (255, 255, 255)

    canvas = [[rgb] * W for _ in range(H)]

    def put(x, y):
        if 0 <= x < W and 0 <= y < H:
            canvas[y][x] = ink

    # 白(墨)色边框:6px,内缩 10px —— 更像"生成的样本页"而非真实内容
    for x in range(10, W - 10):
        for t in range(6):
            put(x, 10 + t)
            put(x, H - 11 - t)
    for y in range(10, H - 10):
        for t in range(6):
            put(10 + t, y)
            put(W - 11 - t, y)

    for text, scale, top in lines:
        cell = 6 * scale                        # 5 点字形 + 1 点字距
        x0 = (W - (len(text) * cell - scale)) // 2
        for i, ch in enumerate(text):
            glyph = FONT.get(ch.upper(), FONT[' '])
            for gy, row in enumerate(glyph):
                for gx, bit in enumerate(row):
                    if bit != '#':
                        continue
                    for dy in range(scale):
                        for dx in range(scale):
                            put(x0 + i * cell + gx * scale + dx, top + gy * scale + dy)

    raw = bytearray()
    for row in canvas:
        raw.append(0)                           # PNG filter type: None
        for px in row:
            raw += bytes(px)

    def chunk(tag, data):
        payload = tag + data
        return (struct.pack('>I', len(data)) + payload +
                struct.pack('>I', zlib.crc32(payload) & 0xffffffff))

    return (b'\x89PNG\r\n\x1a\n' +
            chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(bytes(raw), 9)) +
            chunk(b'IEND', b''))


os.makedirs('src', exist_ok=True)
colors = {
    'page1.png':  ((255, 0, 0),   '1'),
    'page2.png':  ((0, 255, 0),   '2'),
    'page3.png':  ((0, 0, 255),   '3'),
    'page4.png':  ((255, 255, 0), '4'),
    'page10.png': ((255, 0, 255), '10'),
}
for name, (rgb, label) in colors.items():
    with open(f'src/{name}', 'wb') as f:
        f.write(render(rgb, [('TEST PAGE', 3, 56), (label, 10, 116), ('NOT A COMIC', 3, 244)]))

with open('src/note.txt', 'w') as f:
    f.write('not an image\n')
print('📦 src/ 源图就绪(240×320 带标签纯色页)')
PY

# ---- 2. 清理旧产物(只删本轮确实会重建的;可选依赖缺失时保留对应样本) --------
rm -f plain.cbz mac-junk.cbz mixed-content.cbz partial.cbz empty.cbz no-images.cbz corrupted.cbz plain.cbt damaged-page.cbz many-entries.cbz
if [ "$HAVE_PYZIPPER" = yes ]; then
  rm -f encrypted-zip.cbz encrypted-zip-aes.cbz
fi
if [ "$HAVE_PY7ZR" = yes ]; then
  rm -f encrypted-content.cb7 encrypted-header.cb7
fi
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

# ---- 3c. 「包里不只有图片」:图片在子目录 + 嵌套垃圾目录 + 非图片干扰 ------
# 真实形态:用户把整个 vol01/ 目录(而不是它的内容)拖去压缩,macOS 会连带
# 把 __MACOSX/ 放在**第二层**。配 readme.txt / .DS_Store 一起,一次覆盖
# 「混合内容」的全部三种干扰项:非图片扩展名、隐藏文件、打包垃圾目录。
# ⚠️ 这与 §3 根层 __MACOSX 的限制不同:libarchive 只特殊对待**根层**
#    __MACOSX/(按 AppleDouble 解析),第二层的同类目录它按普通条目列出,
#    所以本样本可以端到端驱动(2026-09-18 实测确认,详见 §3 注记)。
# ⚠️ 本样本锁的是一个**真缺陷的回归**:修前 `vol01/__MACOSX/page1.png`
#    会作为第 0 页出现,且自然排序把它排在 vol01/page1.png **前面** ——
#    用户翻开第一页看到的是打包垃圾。
(
  cd staging
  python3 - <<'PY'
import zipfile

with zipfile.ZipFile('../mixed-content.cbz', 'w', zipfile.ZIP_DEFLATED) as z:
    z.write('page1.png',  'vol01/page1.png')
    z.write('page2.png',  'vol01/page2.png')
    z.write('page10.png', 'vol01/page10.png')
    z.write('page1.png',  'vol01/__MACOSX/page1.png')   # 嵌套(第二层)垃圾目录
    z.write('note.txt',   'readme.txt')
    z.writestr('.DS_Store', b'')
print('📦 混合内容样本就绪(3 页在 vol01/ 下 + 嵌套 __MACOSX + txt + 隐藏文件)')
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
# 本机 zip 3.0 不支持 -Z aes256,改用 pyzipper(WinZip AES-256 规范)。
# 缺 pyzipper → 跳过并保留旧产物(旧样本仍有效:它验证的是「打不开」而非内容)。
if [ "$HAVE_PYZIPPER" = yes ]; then
  (
    cd staging
    PYTHONPATH="$PY_DEPS" python3 - <<'PY'
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
else
  echo "⏭️  跳过 encrypted-zip-aes.cbz(缺 pyzipper)"
fi

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
# 用 python tarfile 并显式清空 uname/gname/uid/gid:bsdtar 默认会把本机
# 用户名烧进每个成员头的 ustar 字段(2026-09-14 实测泄漏,发布前必须清)。
(
  cd staging
  python3 - <<'PY'
import tarfile

with tarfile.open('../plain.cbt', 'w', format=tarfile.USTAR_FORMAT) as t:
    for p in ('page1.png', 'page2.png', 'page10.png', 'note.txt'):
        ti = t.gettarinfo(p, arcname=p)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ''
        with open(p, 'rb') as f:
            t.addfile(ti, f)
print('📦 cbt 样本就绪(头字段无本机身份)')
PY
)

# ---- 8b. 单页数据损坏(目录完好) ------------------------------------------
# 2026-09-17 新增,补一个此前**没有任何 fixture 覆盖**的形态:
#   corrupted.cbz 是「整个文件不是归档」——open 阶段就失败了;
#   而真实用户遇到的更常见的是**包能打开、翻到某一页才炸**。
#   完整性检查(ArchiveIntegrityChecker)要验的正是后者,没有样本就只能靠嘴说。
#
# 造法要点:
#   · 用 **ZIP_STORED**(不压缩)+ 固定字节序写入 → 数据的位置与长度都可精确算出;
#   · 只翻转 page2.png 负载中间的一个字节,**中央目录一个字节都不动** →
#     归档依然能列出 3 个图片条目,只有 page2 的 CRC 对不上;
#   · 不用 `zip` CLI 而用 python zipfile:前者会带上时间戳/extra 字段,
#     偏移量随运行时间变化,翻的那一字节就落不到预期位置了。
(
  cd staging
  python3 - <<'PY'
import struct, zipfile

with zipfile.ZipFile('../damaged-page.cbz', 'w', zipfile.ZIP_STORED) as z:
    for p in ('page1.png', 'page2.png', 'page10.png'):
        z.write(p, p)

with zipfile.ZipFile('../damaged-page.cbz') as z:
    offset = z.getinfo('page2.png').header_offset

with open('../damaged-page.cbz', 'r+b') as f:
    f.seek(offset)
    local = f.read(30)                              # 本地文件头固定 30 字节
    name_len, extra_len = struct.unpack('<HH', local[26:30])
    data_at = offset + 30 + name_len + extra_len
    f.seek(data_at + 5)                             # +5:跳过 PNG magic 与块头
    byte = f.read(1)
    f.seek(data_at + 5)
    f.write(bytes([byte[0] ^ 0xFF]))

print('📦 单页损坏样本就绪(目录完好、page2 负载被翻一个字节)')
PY
)

# ---- 8c. 条目数跨过「取消检查点」的大包(2026-09-17 新增) --------------------
# 只为一条性质而存在:**列目录的中途**能被叫停。
#   ArchiveDocument.open 的取消检查每 256 个条目问一次 isCancelled()。
#   其余 fixture 都只有个位数条目 → 检查只在第 0 轮命中过一次,
#   「检查写在循环里、会重复触发」这条性质在它们身上**永远观察不到**:
#   把检查挪到循环外面,那些用例照样全绿。本样本把条目数顶到 300,
#   于是回调序列必然是 [0, 256] —— 用它锁住检查点的位置。
#
# 体积说明:这是唯一一个**刻意**超过 4 KB 的样本(实测 ~32 KB,每个条目约
# 100 字节目录开销)。其它样本都是「真实归档应该长什么样」,这个不是 ——
# 它是**探针**,凑够条目数即可,所以 300 个填充条目用零字节载荷。
# 3 张真页照旧放进去,保证它同时仍是一个合法的漫画包。
(
  cd staging
  python3 - <<'PY'
import zipfile

with zipfile.ZipFile('../many-entries.cbz', 'w', zipfile.ZIP_DEFLATED) as z:
    for p in ('page1.png', 'page2.png', 'page10.png'):
        z.write('../src/' + p, p)
    for i in range(300):
        z.writestr('pad/%04d.txt' % i, '')
print('📦 多条目探针就绪(3 页 + 300 个零字节填充条目)')
PY
)

# ---- 9+10. 7z 双形态加密(设计文档 POC 同款造法:py7zr) --------------------
# 本机无可用 7z CLI(坏包装脚本),改用 py7zr(POC 时就是它):
#   encrypted-content.cb7  内容加密(password + header_encryption=False → 可列目录不可解)
#   encrypted-header.cb7   头部加密(password + header_encryption=True  → 列目录即 FATAL)
# 缺 py7zr → 跳过并保留旧产物。
if [ "$HAVE_PY7ZR" = yes ]; then
  (
    cd staging
    PYTHONPATH="$PY_DEPS" python3 - <<'PY'
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
else
  echo "⏭️  跳过 encrypted-content.cb7 / encrypted-header.cb7(缺 py7zr)"
fi

rm -rf staging

echo "✅ fixture 生成完毕:"
ls -l *.cbz *.cbt *.cb7
