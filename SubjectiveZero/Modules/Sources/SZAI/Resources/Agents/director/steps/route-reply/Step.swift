// What WAS this chat turn? The mechanical fact wins first: a turn that grew the
// needs-implementation set drafted real work, so the build fires without spending a query.
// Only the ambiguous remainder asks for a typed ruling — answer (a question answered),
// build (the user wants the graph implemented now), plan (work drafted, building not asked).
// `answer` and `plan` end the traversal; `build` ends it too — the requestBuild EFFECT is
// what starts the run, not an edge.
struct Ruling: Codable { enum Kind: String, Codable { case answer, build, plan }; let kind: Kind }
let step = SZChatRouter("answer", "build", "plan") { ctx in
    if ctx.draftedWork { return .outcome("build", effects: ["requestBuild"]) }
    let kind = try await ctx.askModel(template: "route-reply", as: Ruling.self).kind
    return kind == .build ? .outcome("build", effects: ["requestBuild"]) : .outcome(kind.rawValue)
}
