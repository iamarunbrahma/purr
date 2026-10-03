import Foundation

struct Scenario {
    let name: String
    let steps: [(String, String)]
    let expected: String
    let revised: Bool
}
let scenarios = [
    Scenario(name: "partials plus final do not duplicate", steps: [("p", "Hello"), ("p", "Hello world"), ("e", "Hello world")], expected: "Hello world ", revised: false),
    Scenario(name: "final flush adds words without another partial", steps: [("p", "Hello"), ("e", "Hello world")], expected: "Hello world ", revised: false),
    Scenario(name: "repeated partial is harmless", steps: [("p", "Hello"), ("p", "Hello"), ("e", "Hello")], expected: "Hello ", revised: false),
    Scenario(name: "duplicate final EOU is harmless", steps: [("p", "Hello"), ("e", "Hello"), ("e", "Hello")], expected: "Hello ", revised: false),
    Scenario(name: "identical consecutive spoken phrases survive", steps: [("p", "Hello"), ("e", "Hello"), ("p", "Hello"), ("e", "Hello")], expected: "Hello Hello ", revised: false),
    Scenario(name: "phrase boundaries get one separator", steps: [("p", "Hello"), ("e", "Hello"), ("p", "world"), ("e", "world")], expected: "Hello world ", revised: false),
    Scenario(name: "native leading spacing does not double", steps: [("p", "Hello"), ("e", "Hello"), ("p", " world"), ("e", " world")], expected: "Hello world ", revised: false),
    Scenario(name: "existing trailing whitespace is preserved", steps: [("p", "Hello "), ("e", "Hello "), ("p", "world\n"), ("e", "world\n")], expected: "Hello world\n", revised: false),
    Scenario(name: "empty events emit no space", steps: [("p", ""), ("e", "")], expected: "", revised: false),
    Scenario(name: "recognition revision does not paste a second sentence", steps: [("p", "Hello"), ("p", "Hi there"), ("e", "Hi there")], expected: "Hello ", revised: true),
    Scenario(name: "short stale snapshot can recover without duplicates", steps: [("p", "Hello"), ("p", "Hell"), ("p", "Hello world"), ("e", "Hello world")], expected: "Hello world ", revised: true),
    Scenario(name: "final-only utterance works", steps: [("e", "Hello")], expected: "Hello ", revised: false),
    Scenario(name: "Unicode composed characters survive suffix extraction", steps: [("p", "👩🏽‍💻 café"), ("p", "👩🏽‍💻 café 漢字"), ("e", "👩🏽‍💻 café 漢字")], expected: "👩🏽‍💻 café 漢字 ", revised: false),
    Scenario(name: "final punctuation is appended once", steps: [("p", "Hello"), ("e", "Hello."), ("e", "Hello.")], expected: "Hello. ", revised: false),
]
for scenario in scenarios {
    var transcript = CursorTranscript()
    var output = ""
    for (kind, text) in scenario.steps {
        output += kind == "p" ? transcript.partial(text) : transcript.endOfUtterance(text)
    }
    output += transcript.finish()
    precondition(output == scenario.expected, "\(scenario.name): \(output.debugDescription) != \(scenario.expected.debugDescription)")
    precondition(transcript.hadRevision == scenario.revised, "\(scenario.name): revision detection")
    precondition(transcript.finish().isEmpty, "\(scenario.name): repeated stop must be harmless")
}
print("Passed \(scenarios.count) cursor-stream scenarios.")
