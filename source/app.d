import std.stdio;
import std.file;
import std.path;
import std.regex;
import std.array;
import std.getopt;
import std.algorithm;
import std.container;
import sdlang;
import std.process;

struct Rule {
    string type;
    string target;
    string replacement;
}

class MigrationEngine {
    Rule[] rules;

    void loadRules(string sdlPath) {
        if (!exists(sdlPath)) {
            writeln("Rules file not found: ", sdlPath);
            return;
        }

        try {
            Tag root = parseFile(sdlPath);
            foreach (tag; root.tags) {
                if (tag.name == "ruleset" || tag.name == "rule") {
                    foreach (ruleTag; tag.tags) {
                        Rule r;
                        r.type = ruleTag.name;
                        r.target = ruleTag.values[0].get!string;
                        r.replacement = ruleTag.values[1].get!string;
                        rules ~= r;
                    }
                }
            }
        } catch (Exception e) {
            writeln("Error parsing SDL rules: ", e.msg);
        }
    }

    string applyRules(string content) {
        foreach (rule; rules) {
            if (rule.type == "replace") {
                content = content.replace(rule.target, rule.replacement);
            } else if (rule.type == "regex") {
                auto re = regex(rule.target);
                content = replaceAll(content, re, rule.replacement);
            }
        }
        return content;
    }
}

string[] findMigrationPath(string rulesDir, string fromVer, string toVer) {
    struct Edge {
        string to;
        string file;
    }
    Edge[][string] graph;

    if (!exists(rulesDir)) return [];

    foreach (DirEntry entry; dirEntries(rulesDir, SpanMode.depth)) {
        if (entry.isFile && entry.name.endsWith(".sdl")) {
            auto base = baseName(entry.name, ".sdl");
            auto parts = base.split("-");
            if (parts.length == 2) {
                graph[parts[0]] ~= Edge(parts[1], entry.name);
            }
        }
    }

    // BFS to find shortest path
    string[][string] parent;
    string[][string] parentFile;
    DList!string queue;
    queue.insertBack(fromVer);
    bool[string] visited;
    visited[fromVer] = true;

    while (!queue.empty) {
        auto current = queue.front;
        queue.removeFront();

        if (current == toVer) {
            // Reconstruct path
            string[] path;
            auto curr = toVer;
            while (curr != fromVer) {
                path ~= parentFile[curr][0];
                curr = parent[curr][0];
            }
            reverse(path);
            return path;
        }

        if (current in graph) {
            foreach (edge; graph[current]) {
                if (edge.to !in visited) {
                    visited[edge.to] = true;
                    parent[edge.to] ~= current;
                    parentFile[edge.to] ~= edge.file;
                    queue.insertBack(edge.to);
                }
            }
        }
    }

    return [];
}

int main(string[] args) {
    string path = ".";
    string rulesDir = "rules";
    string rulesRepo = "";
    string rulesRepoBranch = "main";
    string fromVer = "";
    string toVer = "";
    string library = "";
    string extensions = ".py,.cpp,.h";
    string domain = "code";
    string outDir = "";
    bool inPlace = false;
    bool dryRun = true;

    auto helpInformation = getopt(
        args,
        "path|p", "Path to process", &path,
        "rules-dir|R", "Directory containing SDL rules (local)", &rulesDir,
        "rules-repo", "Git repository URL for rulesets", &rulesRepo,
        "rules-repo-branch", "Branch for the rules repository (default: main)", &rulesRepoBranch,
        "library|L", "Library/Binding subpath (e.g., python/qt)", &library,
        "from|f", "Source version (e.g., 5.15)", &fromVer,
        "to|t", "Target version (e.g., 6.0)", &toVer,
        "extensions|e", "Comma-separated extensions", &extensions,
        "domain|D", "Domain to operate in (code|filesystem)", &domain,
        "out-dir|o", "Output directory for transformed files", &outDir,
        "in-place|i", "Modify files in-place (destructive)", &inPlace,
        "dry-run|d", "Explicit dry run (default)", &dryRun
    );

    if (inPlace) dryRun = false;
    if (outDir != "") dryRun = false;

    if (helpInformation.helpWanted) {
        defaultGetoptPrinter("Evolution Engine", helpInformation.options);
        return 0;
    }

    // 1. Remote URL Support
    string actualRulesDir = rulesDir;
    if (rulesDir.startsWith("http://") || rulesDir.startsWith("https://")) {
        string tempRoot = buildPath(tempDir(), "evolution-engine-cache");
        import std.digest.md;
        string urlHash = rulesDir.digest!MD5.toHexString().idup;
        string downloadPath;
        if (rulesDir.endsWith(".zip")) downloadPath = buildPath(tempRoot, urlHash ~ ".zip");
        else if (rulesDir.endsWith(".tar.gz") || rulesDir.endsWith(".tgz")) downloadPath = buildPath(tempRoot, urlHash ~ ".tar.gz");
        else { writeln("Unrecognized remote archive format."); return 1; }

        if (!exists(downloadPath)) {
            mkdirRecurse(tempRoot);
            import std.net.curl;
            writeln("Downloading: ", rulesDir);
            download(rulesDir, downloadPath);
        }
        actualRulesDir = downloadPath;
    }

    // 2. Local Archive Support (Extra extraction step)
    string archivePath = "";
    string subPath = "";
    string[] pathParts = actualRulesDir.split(dirSeparator);
    foreach (i, part; pathParts) {
        if (part.endsWith(".zip") || part.endsWith(".tar.gz") || part.endsWith(".tgz")) {
            archivePath = pathParts[0 .. i+1].join(dirSeparator);
            subPath = pathParts[i+1 .. $].join(dirSeparator);
            break;
        }
    }

    if (archivePath != "") {
        string tempRoot = buildPath(tempDir(), "evolution-engine-cache");
        import std.digest.md;
        string hash = archivePath.digest!MD5.toHexString();
        string extractDir = buildPath(tempRoot, hash);
        if (!exists(extractDir)) {
            mkdirRecurse(extractDir);
            if (archivePath.endsWith(".zip")) {
                import std.zip;
                auto zip = new ZipArchive(read(archivePath));
                foreach (name, am; zip.directory) {
                    zip.expand(am);
                    string target = buildPath(extractDir, name);
                    if (name.endsWith("/") || name.endsWith("\\")) { if (!exists(target)) mkdirRecurse(target); }
                    else { string d = dirName(target); if (!exists(d)) mkdirRecurse(d); std.file.write(target, am.expandedData); }
                }
            } else {
                auto pid = spawnProcess(["tar", "-xzf", archivePath, "-C", extractDir]);
                if (wait(pid) != 0) { writeln("Error extracting archive."); return 1; }
            }
        }
        
        // Finalize extraction dir
        if (subPath == "") {
            auto entries = dirEntries(extractDir, SpanMode.shallow).filter!(e => e.isDir).array;
            actualRulesDir = (entries.length == 1) ? entries[0].name : extractDir;
        } else actualRulesDir = buildPath(extractDir, subPath);
    }

    // 3. Universal "Smart Dive" (for both archives and local folders)
    if (exists(buildPath(actualRulesDir, "rules"))) {
         bool looksLikeRuleset = false;
         if (domain == "filesystem") {
             string[] osFolders = ["linux", "windows", "mac", "bsd", "darwin"];
             foreach(os; osFolders) if(exists(buildPath(actualRulesDir, os))) { looksLikeRuleset = true; break; }
         } else {
             foreach(e; dirEntries(actualRulesDir, SpanMode.shallow)) if(e.name.endsWith(".sdl")) { looksLikeRuleset = true; break; }
         }
         if (!looksLikeRuleset) actualRulesDir = buildPath(actualRulesDir, "rules");
    }
    rulesDir = actualRulesDir;

    // 4. Remote Repo Support
    string tmpRulesDir = ".evolution-rules-tmp";
    auto cleanup = {
        if (exists(tmpRulesDir)) {
            version(Windows) executeShell("rmdir /s /q " ~ tmpRulesDir);
            else rmdirRecurse(tmpRulesDir);
        }
    };

    if (rulesRepo != "") {
        cleanup();
        auto cloneCmd = executeShell("git clone --depth 1 -b " ~ rulesRepoBranch ~ " " ~ rulesRepo ~ " " ~ tmpRulesDir);
        if (cloneCmd.status != 0) { writeln("Failed to clone rules repository."); return 1; }
        rulesDir = tmpRulesDir;
    }
    scope(exit) if (rulesRepo != "") cleanup();

    auto engine = new MigrationEngine();
    string[] ruleFiles;

    if (domain == "filesystem") {
        string toContext = toVer;
        string intent = args.length > 1 ? args[1] : "";
        if (toContext == "") { writeln("Error: --to (context) required."); return 1; }
        if (intent == "") { writeln("Error: intent name required."); return 1; }
        ruleFiles = resolveIntent(buildPath(rulesDir, "filesystem"), toContext, intent);
    } else {
        // Code domain
        if (fromVer != "" && toVer != "") {
            string codeRulesRoot = buildPath(rulesDir, "code");
            if (!exists(codeRulesRoot)) codeRulesRoot = rulesDir; // Fallback
            string searchDir = buildPath(codeRulesRoot, library);
            ruleFiles = findMigrationPath(searchDir, fromVer, toVer);
        }
    }

    if (ruleFiles.length == 0) {
        writeln("No rules found for ", domain, (library != "" ? " (" ~ library ~ ")" : ""), " from ", fromVer, " to ", toVer);
        return 1;
    }

    if (domain == "code") writeln("Migration path: ", fromVer, " -> ", toVer, " using ", ruleFiles);
    else writeln("Resolved: ", ruleFiles);

    foreach (f; ruleFiles) engine.loadRules(f);

    auto extList = extensions.split(",");
    if (!exists(path)) { writeln("Path does not exist: ", path); return 1; }

    if (isDir(path)) {
        foreach (DirEntry entry; dirEntries(path, SpanMode.depth)) {
            if (entry.isFile && extList.canFind(extension(entry.name))) {
                processFile(entry.name, engine, dryRun, outDir, path);
            }
        }
    } else {
        processFile(path, engine, dryRun, outDir, dirName(path));
    }

    return 0;
}

void processFile(string fileName, MigrationEngine engine, bool dryRun, string outDir, string baseRoot) {
    auto content = readText(fileName);
    auto newContent = engine.applyRules(content);

    if (newContent != content) {
        if (dryRun) {
            writeln("Plan: update ", fileName);
        } else {
            string targetPath = fileName;
            if (outDir != "") {
                string relative = fileName.relativePath(baseRoot);
                targetPath = buildPath(outDir, relative);
                string d = dirName(targetPath);
                if (!exists(d)) mkdirRecurse(d);
            }
            std.file.write(targetPath, newContent);
            writeln("Updated: ", targetPath);
        }
    }
}

string[] resolveIntent(string rulesDir, string toContext, string intent) {
    string[] contextPath = toContext.split("/");
    string[] bestFiles;
    
    // Check for global intent fallback first (at root of filesystem rules)
    string globalIntentPath = buildPath(rulesDir, intent ~ ".sdl");
    string defaultGlobalPath = buildPath(rulesDir, "default", intent ~ ".sdl");
    
    // Traverse down the context hierarchy
    string currentDir = rulesDir;
    foreach (part; contextPath) {
        currentDir = buildPath(currentDir, part);
        string specific = buildPath(currentDir, intent ~ ".sdl");
        string def = buildPath(currentDir, "default", intent ~ ".sdl");
        if (exists(specific)) bestFiles = [specific];
        else if (exists(def)) bestFiles = [def];
    }
    
    if (bestFiles.length == 0) {
        if (exists(globalIntentPath)) return [globalIntentPath];
        if (exists(defaultGlobalPath)) return [defaultGlobalPath];
    }
    
    return bestFiles;
}
