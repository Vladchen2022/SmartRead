import Foundation

enum AIValidationPolicy {
    static let version = "local-checks-v4"
}

enum SentenceAnalysisQuality {
    static func issues(in result: SentenceAnalysis) -> [String] {
        let example = WordExplanation(lemma: result.keyExpression, partOfSpeechZh: "表达",
            meaningZh: result.expressionMeaningZh, usageNoteZh: result.usageNoteZh,
            exampleEnglish: result.exampleEnglish, exampleChinese: result.exampleChinese)
        var problems = WordExampleQuality.issues(in: example)
        for (index, expression) in result.similarExpressions.enumerated() {
            let pair = WordExplanation(lemma: "", partOfSpeechZh: "", meaningZh: "", usageNoteZh: "",
                exampleEnglish: expression.english, exampleChinese: expression.chinese)
            problems += WordExampleQuality.issues(in: pair).map { "相近表达 \(index + 1)：\($0)" }
        }
        if Set(result.similarExpressions.map { $0.english.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }).count != 2 {
            problems.append("两条相近表达不能重复。")
        }
        return problems
    }
}
