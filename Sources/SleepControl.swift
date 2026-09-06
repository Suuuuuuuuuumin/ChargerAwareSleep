import Foundation

enum SleepControlError: Error, Equatable {
    /// sudo 또는 pmset 이 0 이 아닌 종료 코드를 냈다.
    case commandFailed(status: Int32, message: String)
}

/// disablesleep 을 바꾸는 유일한 경로. root 가 필요하다.
/// 앱은 sudoers 를 수정하지 않는다 — 그 능력 자체가 규칙 한 줄보다 큰 구멍이다.
enum SleepControl {

    /// pmset 의 disablesleep 은 man 페이지에 없는 미문서화 설정이다.
    /// macOS major 업그레이드 때마다 회귀 확인이 필요하다. (spec 실측 05)
    @discardableResult
    static func set(_ disabled: Bool) -> Result<Void, SleepControlError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -n: 암호를 묻지 않는다. 규칙이 없으면 프롬프트로 멈추지 않고 즉시 실패한다.
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return .failure(.commandFailed(status: -1, message: "\(error)"))
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let raw = String(data: errorData, encoding: .utf8) ?? ""
            let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.commandFailed(
                status: process.terminationStatus,
                message: message.isEmpty ? "sudo 가 코드 \(process.terminationStatus) 로 실패했습니다" : message))
        }
        return .success(())
    }
}
