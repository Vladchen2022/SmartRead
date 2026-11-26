import SwiftUI

struct AssistantPracticeRequest {
    enum Step: Equatable {
        case exercise
        case feedback(exercise: String, response: String)
    }

    let turn: AssistantQuestionTurn
    let step: Step
}

struct AssistantQuestionPracticeSheet: View {
    let turn: AssistantQuestionTurn
    let reader: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var exercise = ""
    @State private var response = ""
    @State private var feedback = ""
    @State private var failure: String?
    @State private var isWaiting = true
    @State private var step = AssistantPracticeRequest.Step.exercise
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("用一下").font(.title2.bold())
            if let passage = turn.reference?.passage {
                Text(passage).textSelection(.enabled).foregroundStyle(.secondary).lineLimit(4)
            }
            if !exercise.isEmpty {
                practiceText(exercise).accessibilityIdentifier("assistantExercise")
                TextField("写下你的英文答案", text: $response, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .disabled(isWaiting)
                    .accessibilityIdentifier("assistantExerciseResponse")
            }
            if !feedback.isEmpty {
                practiceText(feedback).accessibilityIdentifier("assistantExerciseFeedback")
            }
            if let failure { Text(failure).foregroundStyle(ReaderPalette.warning) }
            if isWaiting { ProgressView("本地模型正在生成…").controlSize(.small) }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                if failure != nil {
                    Button("重试") { requestID = UUID() }.disabled(isWaiting)
                } else if !exercise.isEmpty {
                    Button("提交答案") {
                        step = .feedback(exercise: exercise, response: response.trimmingCharacters(in: .whitespacesAndNewlines))
                        requestID = UUID()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWaiting || response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || response.count > 1000)
                    .accessibilityIdentifier("submitAssistantExercise")
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .task(id: requestID) {
            isWaiting = true
            failure = nil
            do {
                let result = try await reader.answerPractice(AssistantPracticeRequest(turn: turn, step: step))
                try Task.checkCancellation()
                switch step {
                case .exercise: exercise = result
                case .feedback: feedback = result
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { failure = ReaderModel.connectionMessage(error) }
            }
            if !Task.isCancelled { isWaiting = false }
        }
    }

    private func practiceText(_ text: String) -> some View {
        AnswerText(answer: text, fontSize: 14)
            .environment(\.openURL, OpenURLAction { _ in .discarded })
    }
}
