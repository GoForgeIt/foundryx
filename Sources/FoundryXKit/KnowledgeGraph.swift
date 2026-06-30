import Foundation

/// The knowledge graph the phone RENDERS — entities (people / projects / topics / places)
/// the user's conversations are about, their connections, and where they came up.
///
/// COMPUTED server-side (Lore/Anvil — Nick's domain); the phone is a THIN CLIENT that fetches
/// + displays. Door endpoint + JSON shape are TBD with Nick (see deliverables/F_nick-backend-asks.md
/// §4 and TODO(nick) in KnowledgeGraphView.load()). This is the phone's stable rendering contract.
public struct KnowledgeGraph: Codable, Equatable, Sendable {
    public var nodes: [GraphNode]
    public init(nodes: [GraphNode] = []) { self.nodes = nodes }
    public var isEmpty: Bool { nodes.isEmpty }
}

/// One entity in the graph.
public struct GraphNode: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// person | project | topic | place
    public var kind: String
    public var mentions: Int
    /// Edges to other entities (the connections).
    public var related: [GraphEdge]
    /// The conversations this entity appeared in.
    public var conversations: [GraphConversationRef]

    public init(id: String, label: String, kind: String, mentions: Int,
                related: [GraphEdge] = [], conversations: [GraphConversationRef] = []) {
        self.id = id; self.label = label; self.kind = kind; self.mentions = mentions
        self.related = related; self.conversations = conversations
    }
}

/// A connection from one node to another.
public struct GraphEdge: Codable, Equatable, Sendable, Identifiable {
    /// The TARGET node's id.
    public var id: String
    public var label: String
    public var weight: Int
    public init(id: String, label: String, weight: Int) {
        self.id = id; self.label = label; self.weight = weight
    }
}

/// A reference back to a conversation (captureId) an entity appeared in.
public struct GraphConversationRef: Codable, Equatable, Sendable, Identifiable {
    /// The captureId.
    public var id: String
    public var title: String
    public var when: String?
    public init(id: String, title: String, when: String? = nil) {
        self.id = id; self.title = title; self.when = when
    }
}

#if DEBUG
public extension KnowledgeGraph {
    /// Sample graph for headless screenshots (Kevin-flavored). NOT shipped data.
    static var sample: KnowledgeGraph {
        KnowledgeGraph(nodes: [
            GraphNode(id: "n_lantis", label: "Lantis", kind: "project", mentions: 6,
                      related: [GraphEdge(id: "n_sarah", label: "Sarah", weight: 3),
                                GraphEdge(id: "n_intake", label: "Intake workflow", weight: 4)],
                      conversations: [GraphConversationRef(id: "cap_1", title: "Lantis kickoff call", when: "Mon, Jun 29"),
                                      GraphConversationRef(id: "cap_2", title: "Standup", when: "Tue, Jun 30")]),
            GraphNode(id: "n_sarah", label: "Sarah", kind: "person", mentions: 3,
                      related: [GraphEdge(id: "n_wedding", label: "Wedding", weight: 2)],
                      conversations: [GraphConversationRef(id: "cap_3", title: "Wedding planning", when: "Sun, Jun 28")]),
            GraphNode(id: "n_mom", label: "Mom", kind: "person", mentions: 2,
                      conversations: [GraphConversationRef(id: "cap_4", title: "Call with Mom", when: "Sat, Jun 27")]),
            GraphNode(id: "n_intake", label: "Intake workflow", kind: "topic", mentions: 4,
                      related: [GraphEdge(id: "n_lantis", label: "Lantis", weight: 4)],
                      conversations: [GraphConversationRef(id: "cap_1", title: "Lantis kickoff call", when: "Mon, Jun 29")]),
            GraphNode(id: "n_wedding", label: "Wedding", kind: "topic", mentions: 4,
                      conversations: [GraphConversationRef(id: "cap_3", title: "Wedding planning", when: "Sun, Jun 28")]),
            GraphNode(id: "n_launch", label: "Launch", kind: "topic", mentions: 3, conversations: [])
        ])
    }
}
#endif
