import Foundation

/// Model representing a navigation failure.
/// Error codes follow Chromium net error conventions (negative integers).
package struct NavigationError: Identifiable {
    package let id = UUID()
    package let navigationId: Int64
    package let url: String
    package let errorCode: Int32
    package let errorDescription: String

    /// User-friendly title for the error page.
    package var localizedTitle: String {
        switch errorCode {
        case -105:
            return "找不到该网站"
        case -106:
            return "无法连接到互联网"
        case -118:
            return "连接超时"
        case -200:
            return "证书错误"
        case -310:
            return "重定向次数过多"
        case -137:
            return "域名解析失败"
        case -2:
            return "请求被取消"
        default:
            return "无法访问此页面"
        }
    }

    /// User-friendly description for the error page.
    package var localizedMessage: String {
        switch errorCode {
        case -105:
            return "请检查网址是否正确，或稍后重试。"
        case -106:
            return "请检查网络连接是否正常。"
        case -118:
            return "服务器响应时间过长，请稍后重试。"
        case -200:
            return "该网站的安全证书存在问题。"
        case -310:
            return "该页面重定向次数过多，无法继续加载。"
        case -137:
            return "无法解析域名，请检查网址。"
        default:
            return errorDescription.isEmpty ? "发生了未知错误。" : errorDescription
        }
    }

    /// Optional suggestion text shown below the error message.
    package var suggestion: String? {
        switch errorCode {
        case -105, -137:
            return "检查网址拼写是否正确"
        case -106:
            return "检查 Wi-Fi 或网线连接"
        case -118:
            return "服务器可能暂时不可用"
        case -310:
            return "尝试返回上一页"
        default:
            return nil
        }
    }

    /// True if ERR_TOO_MANY_REDIRECTS — show "go back" instead of "retry".
    package var requiresGoBack: Bool { errorCode == -310 }

    /// True if ERR_ABORTED — user stopped loading, do NOT show error page.
    package var isAborted: Bool { errorCode == -3 }
}
