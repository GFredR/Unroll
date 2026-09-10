// AI-Generated | 可修改
// NaturalSort —— 自然排序(设计文档 §2.1 P0 第 8 条)
// ----------------------------------------------------------------------------
// 漫画页序必须是 page2 < page10(自然排序),字典序会得到 page10 < page2,
// 这是看图器最经典的翻页事故之一。
//
// 算法:把路径切成「数字段 / 非数字段」交替的段序列,逐段比较——
//   · 数字段:先比数值(去前导零后的位数,再同位数字典序),数值相等用
//     原始段字典序破平局(前导零多者在前:"p001" < "p01" < "p1",§4.1 注)
//   · 非数字段:先大小写不敏感比,再原始串破平局(保证全序,确定性)
//   · 段类型不同的位置:数字段在前(对齐 ASCII '0'-'9' < 字母的直觉)
//   · 一方是另一方前缀:段少者在前
// 数字只认 ASCII 0-9(全角"１２"不参与数值比较,按普通字符处理)。
// M0 的字典序占位已被本实现替换;App 层契约测试的占位断言已同步反转。
import Foundation   // ComparisonResult

public enum NaturalSort {

    /// a 是否应排在 b 之前(严格小于;二者等序时返回 false)
    public static func less(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    /// 全序比较:a < b → .orderedAscending;等序 → .orderedSame
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lRuns = tokenize(lhs)
        let rRuns = tokenize(rhs)

        for (l, r) in zip(lRuns, rRuns) {
            // 段类型不同:数字段 < 非数字段(约定,保证全序)
            if l.isDigits != r.isDigits {
                return l.isDigits ? .orderedAscending : .orderedDescending
            }
            if l.isDigits {
                let c = compareNumeric(l.text, r.text)
                if c != .orderedSame { return c }
            } else {
                let c = compareText(l.text, r.text)
                if c != .orderedSame { return c }
            }
        }
        // 公共前缀段全部等序:段数少者在前("page" < "page2")
        if lRuns.count != rRuns.count {
            return lRuns.count < rRuns.count ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    // MARK: - 段切分

    /// 交替的数字 / 非数字段;空串切成空段序列
    private static func tokenize(_ s: String) -> [(text: Substring, isDigits: Bool)] {
        var runs: [(text: Substring, isDigits: Bool)] = []
        var start = s.startIndex
        var currentIsDigit: Bool? = nil

        for i in s.indices {
            let isDigit = s[i].isASCIIDigit
            if let was = currentIsDigit, was != isDigit {
                runs.append((s[start..<i], was))
                start = i
            }
            currentIsDigit = isDigit
        }
        if let isDigit = currentIsDigit, start < s.endIndex {
            runs.append((s[start...], isDigit))
        }
        return runs
    }

    // MARK: - 段比较

    /// 数字段比较:数值优先,前导零破平局。
    /// 去前导零后:位数不同 → 位数即大小;位数相同 → 字典序即数值序;
    /// 数值相等 → 原始段字典序(前导零多者在前,如 "02" < "2")。
    private static func compareNumeric(_ l: Substring, _ r: Substring) -> ComparisonResult {
        let lt = l.drop { $0 == "0" }   // 去前导零;"000" → 空
        let rt = r.drop { $0 == "0" }
        if lt.count != rt.count {
            return lt.count < rt.count ? .orderedAscending : .orderedDescending
        }
        if lt != rt {
            return lt < rt ? .orderedAscending : .orderedDescending
        }
        if l != r {
            return l < r ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    /// 非数字段比较:大小写不敏感优先("page" == "Page"),
    /// 仍相等用原始串破平局("Page" < "page",ASCII 大写在前)——确定性全序
    private static func compareText(_ l: Substring, _ r: Substring) -> ComparisonResult {
        let ll = l.lowercased()
        let rr = r.lowercased()
        if ll != rr {
            return ll < rr ? .orderedAscending : .orderedDescending
        }
        if l != r {
            return l < r ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}

private extension Character {
    /// 只认 ASCII 0-9;全角数字、其它数字文字不参与数值段
    var isASCIIDigit: Bool {
        guard let scalar = asciiValue else { return false }
        return scalar >= 48 && scalar <= 57
    }
}
