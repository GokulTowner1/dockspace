import Foundation
import SQLite3
import os.log

final class SessionDatabase {
    private let log = Logger(subsystem: "com.dockspace.app", category: "SessionDatabase")
    private var db: OpaquePointer?

    private var dbURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Dockspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.db")
    }

    init() {
        openDatabase()
        createTable()
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }

    private func openDatabase() {
        let path = dbURL.path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            log.error("Failed to open database at \(path)")
        } else {
            log.info("Database opened successfully at \(path)")
        }
    }

    private func createTable() {
        let query = """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            project_path TEXT NOT NULL,
            preferred_ide TEXT NOT NULL,
            terminal_tabs TEXT NOT NULL,
            browser_urls TEXT NOT NULL,
            window_positions TEXT NOT NULL,
            running_commands TEXT NOT NULL,
            hotkey_code INTEGER,
            hotkey_modifiers INTEGER,
            created_at REAL,
            updated_at REAL
        );
        """
        var errMsg: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, query, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
            log.error("Failed to create sessions table: \(error)")
            if let errMsg { sqlite3_free(errMsg) }
        }
    }

    func loadSessions() -> [WorkspaceSession] {
        var sessions: [WorkspaceSession] = []
        let query = "SELECT id, name, project_path, preferred_ide, terminal_tabs, browser_urls, window_positions, running_commands, hotkey_code, hotkey_modifiers, created_at, updated_at FROM sessions ORDER BY created_at DESC;"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            log.error("Failed to prepare select statement")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let decoder = JSONDecoder()

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawId = sqlite3_column_text(stmt, 0),
                  let rawName = sqlite3_column_text(stmt, 1),
                  let rawPath = sqlite3_column_text(stmt, 2),
                  let rawIde = sqlite3_column_text(stmt, 3),
                  let rawTerminal = sqlite3_column_text(stmt, 4),
                  let rawBrowser = sqlite3_column_text(stmt, 5),
                  let rawWindow = sqlite3_column_text(stmt, 6),
                  let rawCommands = sqlite3_column_text(stmt, 7) else {
                continue
            }

            let idStr = String(cString: rawId)
            let name = String(cString: rawName)
            let projectPath = String(cString: rawPath)
            let preferredIdeStr = String(cString: rawIde)
            let terminalStr = String(cString: rawTerminal)
            let browserStr = String(cString: rawBrowser)
            let windowStr = String(cString: rawWindow)
            let commandsStr = String(cString: rawCommands)

            let hasHotkey = sqlite3_column_type(stmt, 8) != SQLITE_NULL
            let hotkeyCode = hasHotkey ? UInt32(sqlite3_column_int(stmt, 8)) : nil
            let hotkeyModifiers = hasHotkey ? UInt32(sqlite3_column_int(stmt, 9)) : nil

            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))

            guard let uuid = UUID(uuidString: idStr) else { continue }
            let preferredIDE = AppType(rawValue: preferredIdeStr) ?? .cursor

            let terminalTabs = (try? decoder.decode([TerminalTab].self, from: Data(terminalStr.utf8))) ?? []
            let browserURLs = (try? decoder.decode([BrowserURL].self, from: Data(browserStr.utf8))) ?? []
            let windowPositions = (try? decoder.decode([WindowPosition].self, from: Data(windowStr.utf8))) ?? []
            let runningCommands = (try? decoder.decode([String].self, from: Data(commandsStr.utf8))) ?? []

            let session = WorkspaceSession(
                id: uuid,
                name: name,
                projectPath: projectPath,
                preferredIDE: preferredIDE,
                terminalTabs: terminalTabs,
                browserURLs: browserURLs,
                windowPositions: windowPositions,
                runningCommands: runningCommands,
                hotkeyCode: hotkeyCode,
                hotkeyModifiers: hotkeyModifiers,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            sessions.append(session)
        }

        return sessions
    }

    func saveSession(_ session: WorkspaceSession) {
        let query = """
        INSERT OR REPLACE INTO sessions (
            id, name, project_path, preferred_ide, terminal_tabs, browser_urls, window_positions, running_commands, hotkey_code, hotkey_modifiers, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            log.error("Failed to prepare insert statement")
            return
        }
        defer { sqlite3_finalize(stmt) }

        let encoder = JSONEncoder()
        let terminalData = (try? encoder.encode(session.terminalTabs)) ?? Data()
        let browserData = (try? encoder.encode(session.browserURLs)) ?? Data()
        let windowData = (try? encoder.encode(session.windowPositions)) ?? Data()
        let commandsData = (try? encoder.encode(session.runningCommands)) ?? Data()

        sqlite3_bind_text(stmt, 1, session.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, session.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, session.projectPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, session.preferredIDE.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, String(decoding: terminalData, as: UTF8.self), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, String(decoding: browserData, as: UTF8.self), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, String(decoding: windowData, as: UTF8.self), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, String(decoding: commandsData, as: UTF8.self), -1, SQLITE_TRANSIENT)

        if let code = session.hotkeyCode, let mods = session.hotkeyModifiers {
            sqlite3_bind_int(stmt, 9, Int32(code))
            sqlite3_bind_int(stmt, 10, Int32(mods))
        } else {
            sqlite3_bind_null(stmt, 9)
            sqlite3_bind_null(stmt, 10)
        }

        sqlite3_bind_double(stmt, 11, session.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 12, session.updatedAt.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let error = sqlite3_errmsg(db).map { String(cString: $0) } ?? "Unknown error"
            log.error("Failed to save session: \(error)")
        } else {
            log.info("Session '\(session.name)' saved successfully.")
        }
    }

    func deleteSession(id: UUID) {
        let query = "DELETE FROM sessions WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            log.error("Failed to prepare delete statement")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let error = sqlite3_errmsg(db).map { String(cString: $0) } ?? "Unknown error"
            log.error("Failed to delete session: \(error)")
        } else {
            log.info("Session with ID \(id.uuidString) deleted successfully.")
        }
    }

    func clearAll() {
        let query = "DROP TABLE IF EXISTS sessions;"
        var errMsg: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, query, nil, nil, &errMsg) == SQLITE_OK {
            log.info("All sessions dropped successfully.")
            createTable()
        } else {
            let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
            log.error("Failed to drop table: \(error)")
            if let errMsg { sqlite3_free(errMsg) }
        }
    }
}

// Swift bridge helper for SQLITE_TRANSIENT
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
