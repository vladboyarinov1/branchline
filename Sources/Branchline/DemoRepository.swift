import Foundation

enum DemoRepository {
    static func prepare() async throws -> URL {
        try await Task.detached(priority: .utility) {
            let files = FileManager.default
            let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Branchline/Демо", isDirectory: true)
            let finalRepo = directory.appendingPathComponent("Northstar", isDirectory: true)
            if files.fileExists(atPath: finalRepo.appendingPathComponent(".git").path) { return finalRepo }
            let preparation = directory.deletingLastPathComponent()
                .appendingPathComponent("intro-" + UUID().uuidString, isDirectory: true)
            let repo = preparation.appendingPathComponent("Northstar", isDirectory: true)
            let remote = preparation.appendingPathComponent("origin.git", isDirectory: true)
            try files.createDirectory(at: repo, withIntermediateDirectories: true)
            defer { try? files.removeItem(at: preparation) }
            let executable = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
                .first(where: files.isExecutableFile(atPath:)) ?? "/usr/bin/git"

            func run(_ args: [String], day: Int? = nil, author: String = "Анна Морозова") throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.currentDirectoryURL = repo
                process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                                     "-c", "core.fsmonitor=false", "-c", "init.templateDir="] + args
                var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
                environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
                environment["GIT_TERMINAL_PROMPT"] = "0"
                if let day {
                    let date = Date().addingTimeInterval(Double(day) * 86_400)
                    let epoch = Int(date.timeIntervalSince1970)
                    environment["GIT_AUTHOR_DATE"] = "\(epoch) +0000"
                    environment["GIT_COMMITTER_DATE"] = "\(epoch) +0000"
                    environment["GIT_AUTHOR_NAME"] = author
                }
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                        "Команда Git «\(args.first ?? "")» завершилась с кодом \(process.terminationStatus)."])
                }
            }

            func write(_ path: String, _ content: String) throws {
                let url = repo.appendingPathComponent(path)
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
            }
            func commit(_ message: String, _ day: Int, _ author: String = "Анна Морозова") throws {
                try run(["add", "-A"])
                try run(["commit", "-m", message], day: day, author: author)
            }

            try run(["init", "-b", "main", "--quiet"])
            try run(["config", "user.name", "Анна Морозова"])
            try run(["config", "user.email", "anna@example.invalid"])
            try run(["config", "commit.gpgsign", "false"])
            try run(["config", "core.hooksPath", "/dev/null"])
            try write("README.md", "# Northstar\n\nДемонстрационный проект для Branchline.\n")
            try write(".gitignore", "node_modules/\n.DS_Store\n")
            try commit("Начать проект Northstar", -25)
            try write("src/ui/theme.css", ":root {\n  --space: 8px;\n  --surface: #14191f;\n  --accent: #80e4bb;\n}\n")
            try commit("Задать токены интерфейса", -22, "Илья Волков")
            try write("src/core/cache.ts", "export const cache = new Map<string, string>();\n")
            try commit("Добавить кэш для запросов", -20, "Илья Волков")
            try write("docs/architecture.md", "# Архитектура\n\nДанные загружаются по запросу.\n")
            try commit("Описать поток данных", -17)
            try run(["tag", "v0.1.0"])
            try run(["switch", "-c", "develop"])
            try write("src/ui/Dashboard.tsx", oldDashboard)
            try commit("Добавить обзор проекта", -15)
            try run(["switch", "-c", "feature/keyboard"])
            try write("src/ui/shortcuts.ts", "export const shortcuts = { search: '⌘K', close: 'Escape' };\n")
            try commit("Добавить сочетания клавиш", -13, "Илья Волков")
            try write("docs/shortcuts.md", "# Горячие клавиши\n\n⌘K — поиск, Escape — закрыть.\n")
            try commit("Задокументировать сочетания клавиш", -11, "Илья Волков")
            try run(["switch", "develop"])
            try write("src/core/preferences.ts", "export const preferences = { compact: true };\n")
            try commit("Сохранять параметры представления", -12)
            try run(["merge", "--no-ff", "feature/keyboard", "-m", "Объединить изменения клавиатурной навигации"], day: -10)
            try write("src/api/client.ts", "export const requestTimeout = 8000;\n")
            try commit("Ограничить время сетевого запроса", -8, "Илья Волков")
            try write("docs/setup.md", "# Запуск\n\nПоднимите локальный сервер.\n")
            try commit("Обновить инструкцию по запуску", -6)
            try run(["init", "--bare", "--quiet", remote.path])
            try run(["remote", "add", "origin", remote.path])
            try run(["push", "--quiet", "-u", "origin", "main", "develop", "feature/keyboard"])
            try write("src/core/cache.ts", "export const cache = new Map<string, string>();\nexport const clearCache = () => cache.clear();\n")
            try commit("Добавить сброс кэша", -4, "Илья Волков")
            try write("README.md", "# Northstar\n\nДемонстрационный проект для Branchline.\n\n## Навигация\n\nОткройте обзор проекта через боковое меню.\n")
            try commit("Добавить раздел навигации в README", -2)
            try run(["branch", "release/0.2"])
            try write("src/ui/theme.css", ":root {\n  --space: 8px;\n  --surface: #14191f;\n  --accent: #80e4bb;\n  --focus: #98bff2;\n}\n")
            try run(["add", "src/ui/theme.css"])
            try write("src/ui/Dashboard.tsx", newDashboard)
            try write("docs/setup.md", "# Запуск\n\nУстановите зависимости и поднимите локальный сервер.\n")
            try write("src/core/retry.ts", "export const maxAttempts = 3;\nexport const retryDelay = 250;\n")
            try run(["remote", "set-url", "origin", directory.appendingPathComponent("origin.git").path])
            do { try files.moveItem(at: preparation, to: directory) }
            catch {
                // Another window may have finished preparing the demo first.
                guard files.fileExists(atPath: finalRepo.appendingPathComponent(".git").path) else { throw error }
            }
            return finalRepo
        }.value
    }

    private static let oldDashboard = """
    import { useMemo } from 'react';
    import { SummaryCard } from './SummaryCard';

    type Props = {
      projects: Project[];
      selected: string | null;
    };

    export function Dashboard({ projects, selected }: Props) {
      const active = useMemo(
        () => projects.find(project => project.id === selected),
        [projects, selected]
      );

      return (
        <main className="dashboard">
          <header>
            <h1>Projects</h1>
            <p>{projects.length} active projects</p>
          </header>
          <SummaryCard project={active} />
        </main>
      );
    }

    export const dashboardRoute = '/dashboard';

    """

    private static let newDashboard = """
    import { useMemo } from 'react';
    import { SummaryCard } from './SummaryCard';
    import { EmptyProjects } from './EmptyProjects';

    type Props = {
      projects: Project[];
      selected: string | null;
    };

    export function Dashboard({ projects, selected }: Props) {
      const active = useMemo(
        () => projects.find(project => project.id === selected),
        [projects, selected]
      );

      if (projects.length === 0) {
        return <EmptyProjects />;
      }

      return (
        <main className="dashboard">
          <header className="dashboard__header">
            <h1>Project overview</h1>
            <p>{projects.length} active projects</p>
          </header>
          {active && <SummaryCard project={active} />}
        </main>
      );
    }

    export const dashboardRoute = '/dashboard';

    """
}
