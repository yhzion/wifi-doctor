import Testing
import Foundation
@testable import WifiDoctorCore

@Suite struct ReportRendererTests {
    func model() async throws -> ReportModel {
        let path = try await ReportModelBuilderTests().makeStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        return try ReportModelBuilder.build(reader: SessionStore.openReader(path: path),
                                            attachments: [CSVFileInfo(name: "probe.csv", rows: 2000)], sessionFileName: "session-20261015-120000.sqlite", sessionSha256: "ab12")
    }
    @Test func containsSixSectionsAndNumbers() async throws {
        let html = ReportRenderer.render(try await model())
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        for h in ["요약", "판정 근거", "방법론", "대표 끊김", "끊김 전체 표", "첨부"] { #expect(html.contains(h)) }
        #expect(html.contains("총 사건 수: 2"))
        #expect(html.contains("192.0.2.1"))                  // 홉 표
        #expect(html.contains("앱은 스캔을 하지 않았"))        // 방법론
        #expect(html.contains("OS 스캔 캐시 갱신 이벤트는 2회"))
        #expect(html.contains("+0.001 +/- 0.006 time.apple.com"))
        #expect(html.contains("맥 자체 지연으로 판정되어 아래 통계에서 제외됨"))
        #expect(html.contains("probe.csv"))
        #expect(html.contains("ab12"))
        #expect(html.contains("위치 권한 없음"))
        #expect(html.contains("관리자 권한 없이 실행"))
    }
    @Test func inlineSvgAndNoExternalResources() async throws {
        let html = ReportRenderer.render(try await model())
        #expect(html.contains("<svg"))
        #expect(html.contains("<script") == false)
        #expect(html.contains("src=\"http") == false)
        #expect(html.contains("href=\"http") == false)
        #expect(html.contains("@import") == false)
    }
    @Test func escapesUserText() async throws {
        var m = try await model(); m.meta.notes = "<b>x</b>"
        #expect(ReportRenderer.render(m).contains("&lt;b&gt;x&lt;/b&gt;"))
    }
}
