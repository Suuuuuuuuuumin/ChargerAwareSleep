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
    ///
    /// @discardableResult 를 붙이지 않는다: 이 타입의 핵심 원칙이 "실패를 조용히
    /// 삼키지 않는다" 인데 반환값을 버려도 되게 하면 그 반대 문을 여는 셈이다.
    /// 반환값을 의도적으로 무시해야 하는 호출부는 `_ = SleepControl.set(false)` 로 명시한다.
    static func set(_ disabled: Bool) -> Result<Void, SleepControlError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -n: 암호를 묻지 않는다. 규칙이 없으면 프롬프트로 멈추지 않고 즉시 실패한다.
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        // pmset 은 stdout 에 거의 쓰지 않지만, Pipe 로 두고 안 읽으면 커널 버퍼가
        // 차 자식이 write 에서 블록되고 stderr EOF 도 안 와 readDataToEndOfFile() 이
        // 교착될 수 있다. 아무도 안 읽을 거면 처음부터 버린다.
        process.standardOutput = FileHandle.nullDevice

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
