import XCTest
@testable import JMTerm

final class OnceResolverTests: XCTestCase {

    // resolve()가 wait()보다 먼저 호출돼도 wait()는 즉시 반환해야 한다.
    // (기존 구현은 continuation을 버려서 영원히 매달렸다 — testConnection 데드락)
    func testWaitAfterResolveSuccessReturnsImmediately() async {
        let resolver = OnceResolver()
        resolver.resolve(with: .success(()))

        let done = expectation(description: "wait returned")
        Task {
            try? await resolver.wait()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
    }

    // resolve(.failure) 후의 wait()는 저장된 에러를 던져야 한다.
    func testWaitAfterResolveFailureThrowsStoredError() async {
        let resolver = OnceResolver()
        resolver.resolve(with: .failure(SSHSessionError.connectionTimeout))

        let done = expectation(description: "wait threw")
        Task {
            do {
                try await resolver.wait()
                XCTFail("wait()가 에러를 던지지 않음")
            } catch {
                if case SSHSessionError.connectionTimeout = error {} else {
                    XCTFail("저장된 에러가 아님: \(error)")
                }
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 2)
    }

    // 기존 동작 유지: wait() 중에 resolve()가 오면 재개된다.
    func testResolveAfterWaitResumes() async {
        let resolver = OnceResolver()

        let done = expectation(description: "wait returned")
        Task {
            try? await resolver.wait()
            done.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(100))
        resolver.resolve(with: .success(()))
        await fulfillment(of: [done], timeout: 2)
    }

    // 두 번째 resolve는 무시되어야 한다 (첫 결과가 보존됨).
    func testSecondResolveIsIgnored() async {
        let resolver = OnceResolver()
        resolver.resolve(with: .failure(SSHSessionError.connectionTimeout))
        resolver.resolve(with: .success(()))

        let done = expectation(description: "wait threw first result")
        Task {
            do {
                try await resolver.wait()
                XCTFail("첫 결과(failure)가 보존되지 않음")
            } catch {
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 2)
    }
}
