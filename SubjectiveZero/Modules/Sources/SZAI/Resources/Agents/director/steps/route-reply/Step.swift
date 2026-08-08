// What WAS this chat turn? The mechanical fact wins first: a turn that grew the
// needs-implementation set drafted real work, so the build fires without spending a query.
// Only the ambiguous remainder asks for a typed ruling — answer (a question answered),
// build (the user wants the graph implemented now), plan (work drafted, building not asked).
// `answer` and `plan` end the traversal; `build` ends it too — the requestBuild EFFECT is
// what starts the run, not an edge.
struct Ruling: Codable { enum Kind: String, Codable { case answer, build, plan }; let kind: Kind }
let step = SZChatRouter("answer", "build", "plan") { ctx in
    // draftedWork is EVIDENCE, never a shortcut: the diff sees the graph grow, not WHO
    // grew it, so a node the user dropped while the turn ran would otherwise start a run
    // nobody asked for. The brief carries the fact; the ruling weighs it.
    let kind = try await ctx.askModel(template: "route-reply", as: Ruling.self).kind
    return kind == .build ? .outcome("build", effects: ["requestBuild"]) : .outcome(kind.rawValue)
}
