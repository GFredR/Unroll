// 量一张 Unroll 窗口截图的**版式**,给 verify-ui.sh 做机器断言。
// 为什么需要它:截图能看出「页面铺满了」,但看不出「页面比该有的宽了 15pt、两边各被
// 裁掉 7.5pt」—— 后者在肉眼看来同样是「铺满」。所以要拿**样本页自带的内容**当尺子:
// 生成器给每页画了一条页脚进度条(黑底 + 白色已完成段),白段宽度 = 页宽的 n/总页数,
// 是个已知比例。按滚动视图内容区实宽算出来的期望值与被裁时实测值差 ~13 设备px,
// 足够把「裁切」和「铺满」分开。
//
// 用法:
//   swift Scripts/page_metrics.swift <截图.png>
// 输出(key=value,一行一项,供 shell 取):
//   win=WxH          截图尺寸(设备像素)
//   page1=a..b       最上面那一页内容的行范围(含页脚进度条那几行)
//   gap=a..b         两页之间的空隙行范围
//   page2=a..b       第二页内容的行范围
//   colRight         内容区右边界(= 页面右缘;再往右是窗口背景/滚动条占位)
//   barWhiteRight    页脚进度条**白色段**的右缘(x 从 0 起)
//   blockHeight      最上面那一页的显示高度(设备像素)
//   scrollerStrip    内容区右缘到窗口右缘之间的宽度 —— 系统「始终显示滚动条」时
//                    这一条非 0(macOS 传统滚动条挖走的占位),也是本次裁切 bug 的成因
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments.dropFirst()
guard let path = args.first else {
    FileHandle.standardError.write(Data("用法: page_metrics.swift <截图.png>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: path)
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("读不出图:\(path)\n".utf8))
    exit(2)
}

let w = img.width, h = img.height
guard w > 8, h > 8 else { exit(2) }

var buf = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("建不出位图上下文\n".utf8))
    exit(2)
}
// **不要**再翻一次。CG 位图的内存第 0 行本来就是画面顶部(坐标原点在左下角是
// 坐标系的事,与内存布局无关)。加一层 translate+scale 会把整幅图弄成上下颠倒 ——
// 实测过一次:分块结果整个镜像(page2 跑到最上面、标题栏跑到最下面)。
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

@inline(__always)
func lum(_ x: Int, _ y: Int) -> Int {
    let o = (y * w + x) * 4
    return (Int(buf[o]) * 299 + Int(buf[o + 1]) * 587 + Int(buf[o + 2]) * 114) / 1000
}

/// 该行亮像素(画面内容)的采样计数(每 2 像素取一个)。窗口背景近黑,页内容明显亮
func brightCount(_ y: Int) -> Int {
    var n = 0
    var x = 0
    while x < w {
        if lum(x, y) > 60 { n += 1 }
        x += 2
    }
    return n
}

/// x 列上是否有亮像素(rows 里任一行为亮即算)
func columnHasContent(_ x: Int, rows: Range<Int>) -> Bool {
    for y in rows where lum(x, y) > 60 { return true }
    return false
}

/// 该行里「近黑」像素的采样计数 —— 用来认出页脚进度条那一行。
/// 进度条 = 黑底 + 白段,整行九成以上是黑的;页面自身的正常行几乎没有黑像素
func darkCount(_ y: Int) -> Int {
    var n = 0
    var x = 0
    while x < w {
        if lum(x, y) < 30 { n += 1 }
        x += 2
    }
    return n
}

/// 在**已认出是进度条**的那一行上,量白色段的右缘。
///
/// 不能用「从 x=0 起连续 ≥200 的亮段」:样本页自身的浅色噪点亮度就能到 ~210,
/// 白点还会连成串 —— 实测那样量出来是 236(整段图案),而真实白段只有 104。
/// 白段与黑底之间是 253 → 0 的硬跳变,所以找「从亮到黑的第一处跳变」才稳
func barWhiteEdge(row y: Int) -> Int {
    var x = 0
    while x < w - 4 {
        if lum(x, y) < 50, lum(x + 1, y) < 50, lum(x + 2, y) < 50, lum(x + 3, y) < 50 {
            return x
        }
        x += 1
    }
    return 0
}

let counts = (0..<h).map(brightCount)
// 松判据:有 3 个亮采样就算「这一行有内容」。**必须松** —— 页脚进度条那几行
// 绝大多数像素是黑的(只有白段那一小截亮),严判据会把它们切出页外
let loose = counts.map { $0 >= 3 }

/// 连续内容段。允许中间断 1 行(噪点图案可能整行偏暗)。
/// **尾部那几行空行要裁掉**:判定收尾时 miss 已经累到 3,`y` 指的是第 3 个空行,
/// 真正的内容结束在 `y-2`。不裁的话页面段会多带 2 行页间空隙,而页间空隙是
/// **全黑**的 —— 后面按「黑像素最多」找进度条时,选中的会是空隙而不是进度条
func runs(_ flags: [Bool]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var start: Int?
    var miss = 0
    for y in 0..<flags.count {
        if flags[y] {
            if start == nil { start = y }
            miss = 0
        } else if let s = start {
            miss += 1
            if miss > 2 {
                out.append(s..<(y - 2))
                start = nil
                miss = 0
            }
        }
    }
    if let s = start { out.append(s..<flags.count) }
    return out
}

// 「像一页」的判据 = **够高**。标题栏(红绿灯 + 标题文字)在松判据下也是一段连续
// 内容,但它只有 ~47 设备行;真页面按宽度铺满后至少几百行。用「高度 ≥ 120 设备行」
// 把它挡在外面 —— 比「这条够不够亮」稳:标题栏里一行有多少亮采样会随标题长短变,
// 高度不会。
// (试过用「段内最亮那行 ≥ w/4 个亮采样」:实测标题栏那段也能过,因为它自己那一行
//  会被整段的最亮行代表。判据选了会随内容变的量,就会自己失效。)
let pageMinRows = 120
let candidates = runs(loose).filter { $0.count >= pageMinRows }

guard let page1 = candidates.first else {
    FileHandle.standardError.write(Data("整张图没找到页面(只有标题栏?)\n".utf8))
    exit(1)
}
let page2 = candidates.count > 1 ? candidates[1] : nil
let gap: Range<Int>? = page2.map { page1.upperBound..<$0.lowerBound }

// 内容区右边界:拿页面中段的行去扫(避开页脚进度条那几行 —— 那里左侧是白的、
// 右侧是黑的,会把边界认到白段上)
let midRows = (page1.lowerBound + page1.count / 4)..<(page1.upperBound - page1.count / 4)
var colRight = 0
for x in stride(from: w - 1, through: 0, by: -1) where columnHasContent(x, rows: midRows) {
    colRight = x + 1
    break
}

// 页脚进度条:在页尾若干行里认出**黑像素最多、且左端是亮的**那一行。
//
// 两个限定都有来历:光看「黑像素最多」会选中页间空隙(那一行整行全黑,黑像素比
// 进度条那行还多 —— 实测就是这么选中空隙、量出 0 的);而进度条的白段紧贴页左缘,
// 所以左端必然是亮的。页尾那几行里只有进度条同时满足这两条
let barScan = Array(max(page1.lowerBound, page1.upperBound - 24)..<page1.upperBound)
let barRow = barScan
    .filter { lum(0, $0) >= 200 }
    .max { darkCount($0) < darkCount($1) }
let barWhiteRight = (barRow.map { darkCount($0) >= w / 4 } ?? false)
    ? barWhiteEdge(row: barRow!) : 0

func fmt(_ r: Range<Int>?) -> String {
    guard let r else { return "none" }
    return "\(r.lowerBound)..\(r.upperBound)"
}

print("win=\(w)x\(h)")
print("page1=\(fmt(page1))")
print("gap=\(fmt(gap))")
print("page2=\(fmt(page2))")
print("colRight=\(colRight)")
print("barWhiteRight=\(barWhiteRight)")
print("blockHeight=\(page1.count)")
print("scrollerStrip=\(w - colRight)")
