// Sources/JMTerm/Models/FileNode.swift
import Foundation

struct FileNode: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64?
    let permissions: UInt32?
    var children: [FileNode]?
    var isExpanded: Bool = false
}
