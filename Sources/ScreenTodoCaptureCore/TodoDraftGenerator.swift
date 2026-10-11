import Foundation

/// 从 OCR 原文生成待办草稿。
///
/// 这层只做轻量规则，不调用 LLM（大语言模型）。原因是第一版要保证本地可用、
/// 低延迟、少隐私风险。后续可以在这里增加更智能的语义解析。
public struct TodoDraftGenerator {
    /// 常见动作词。命中这些词的行更可能是“真正要做的事”。
    private let actionKeywords = [
        "发", "发送", "给", "确认", "跟进", "处理", "安排", "提醒", "看一下", "改",
        "修", "提交", "同步", "回复", "联系", "准备", "报价", "合同", "会议", "todo",
        "TODO", "作业", "论文", "报告", "实验", "复习", "考试", "预习", "课程", "DDL",
        "deadline", "assignment", "essay", "quiz", "exam", "follow up", "confirm", "send", "review"
    ]

    /// 聊天软件界面里常见但不适合进入待办标题的 UI 噪声。
    private let noiseLines = [
        "发送", "按住说话", "表情", "文件", "图片", "视频", "聊天信息", "搜索", "语音输入",
        "朋友圈", "通讯录", "发现", "我", "QQ", "微信", "WeChat"
    ]

    public init() {}

    /// 将 OCR 原文转换成可确认的待办草稿。
    ///
    /// `sourceApplication` 来自当前前台应用，用来记录待办上下文。
    public func makeDraft(
        from recognizedText: String,
        sourceApplication: String,
        createdAt: Date = Date()
    ) -> TodoDraft {
        let cleanedText = normalizedBlock(recognizedText)
        let lines = usefulLines(from: cleanedText)
        let title = makeTitle(from: lines)
        let dueHint = DateHintExtractor().firstHint(in: cleanedText)

        return TodoDraft(
            title: title,
            originalText: cleanedText,
            sourceApplication: sourceApplication,
            dueHint: dueHint,
            createdAt: createdAt
        )
    }

    /// 保留原始换行结构，但清理每行内部多余空白。
    private func normalizedBlock(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 过滤明显不是聊天正文的短行和界面按钮文案。
    private func usefulLines(from text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard line.count >= 2 else { return false }
                return !noiseLines.contains { line.caseInsensitiveCompare($0) == .orderedSame }
            }
    }

    /// 优先用包含动作词的行做标题；没有动作词时使用第一条有效文本。
    private func makeTitle(from lines: [String]) -> String {
        let preferred = lines.first { line in
            actionKeywords.contains { keyword in
                line.localizedCaseInsensitiveContains(keyword)
            }
        } ?? lines.first

        guard let preferred, !preferred.isEmpty else {
            return "从截图创建的待办"
        }

        return truncate(preferred, limit: 38)
    }

    /// 限制标题长度，避免菜单、通知和文件预览里显示过长。
    private func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        return "\(text[..<index])..."
    }
}

/// 从聊天文本里提取“疑似提醒时间”的轻量规则。
///
/// 当前只返回原文片段，不做自然语言日期转换；例如“明天”不会在这里变成具体日期。
struct DateHintExtractor {
    private let patterns = [
        #"今天|明天|后天|大后天"#,
        #"今晚|明早|明晚|本周[一二三四五六日天]?|下周[一二三四五六日天]?|周[一二三四五六日天]"#,
        #"\d{1,2}\s*[点:：]\s*\d{0,2}"#,
        #"\d{1,2}\s*月\s*\d{1,2}\s*[日号]?"#,
        #"\d{4}[-/]\d{1,2}[-/]\d{1,2}"#,
        #"\b(today|tomorrow|next\s+\w+|deadline)\b"#
    ]

    /// 返回第一个匹配到的时间线索，供确认弹窗提示用户。
    func firstHint(in text: String) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let matchRange = Range(match.range, in: text) else {
                continue
            }

            return String(text[matchRange])
        }

        return nil
    }
}
