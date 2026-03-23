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
    string rulesDir = "rules/qt";
    string rulesRepo = "";
    string rulesRepoBranch = "main";
    string fromVer = "";
    string toVer = "";
    string extensions = ".py,.cpp,.h";
    string domain = "code";
    string outDir = "";
    bool inPlace = false;
    bool dryRun = true; // Non-destructive by default

    auto helpInformation = getopt(
        args,
        "path|p", "Path to process", &path,
        "rules-dir|R", "Directory containing SDL rules (local)", &rulesDir,
        "rules-repo", "Git repository URL for rulesets", &rulesRepo,
        "rules-repo-branch", "Branch for the rules repository (default: main)", &rulesRepoBranch,
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

    if (helpInformation.helpWanted || (fromVer != "" && toVer == "")) {
        defaultGetoptPrinter("Evolution Engine", helpInformation.options);
        return 0;
    }

    // Archive Support (Zip/Tar.gz)
    string actualRulesDir = rulesDir;
    string[] pathParts = rulesDir.split(dirSeparator);
    string archivePath = "";
    string subPath = "";

    foreach (i, part; pathParts) {
        if (part.endsWith(".zip") || part.endsWith(".tar.gz") || part.endsWith(".tgz")) {
            archivePath = pathParts[0 .. i+1].join(dirSeparator);
            subPath = pathParts[i+1 .. $].join(dirSeparator);
            break;
        }
    }

    if (archivePath != "") {
        string tempRoot = buildPath(tempDir(), "evolution-engine-cache");
        // Use a hash of the archive path to avoid collisions but persist if needed
        import std.digest;
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
                    if (name.endsWith("/") || name.endsWith("\\")) {
                        if (!exists(target)) mkdirRecurse(target);
                    } else {
                        string d = dirName(target);
                        if (!exists(d)) mkdirRecurse(d);
                        std.file.write(target, am.expandedData);
                    }
                }
            } else {
                // Tar.gz
                auto pid = spawnProcess(["tar", "-xzf", archivePath, "-C", extractDir]);
                if (wait(pid) != 0) {
                    writeln("Error extracting archive: ", archivePath);
                    return 1;
                }
            }
        }
        
        // Handle the GitHub-style top-level folder if it exists and subPath is empty
        if (subPath == "") {
            auto entries = dirEntries(extractDir, SpanMode.shallow).filter!(e => e.isDir).array;
            if (entries.length == 1) {
                actualRulesDir = entries[0].name;
            } else {
                actualRulesDir = extractDir;
            }
        } else {
            actualRulesDir = buildPath(extractDir, subPath);
        }
        
        // Auto-append 'rules' if it exists and we are at the repo root
        // We dive if 'rules' exists AND the current dir doesn't look like a ruleset itself
        if (exists(buildPath(actualRulesDir, "rules"))) {
             bool looksLikeRuleset = false;
             
             if (domain == "filesystem") {
                 // Does it have OS folders directly?
                 string[] osFolders = ["linux", "windows", "mac", "bsd", "darwin"];
                 foreach(os; osFolders) if(exists(buildPath(actualRulesDir, os))) { looksLikeRuleset = true; break; }
             } else {
                 // Does it have SDL files directly?
                 foreach(e; dirEntries(actualRulesDir, SpanMode.shallow)) if(e.name.endsWith(".sdl")) { looksLikeRuleset = true; break; }
             }
             
             if (!looksLikeRuleset) {
                 actualRulesDir = buildPath(actualRulesDir, "rules");
             }
        }
    }
    
    rulesDir = actualRulesDir;

    // Handle remote rules repository
    string tmpRulesDir = ".evolution-rules-tmp";

    void cleanup() {
        if (exists(tmpRulesDir)) {
            version(Windows) {
                executeShell("rmdir /s /q " ~ tmpRulesDir);
            } else {
                rmdirRecurse(tmpRulesDir);
            }
        }
    }

    if (rulesRepo != "") {
        cleanup();
        
        auto cloneCmd = executeShell("git clone --depth 1 -b " ~ rulesRepoBranch ~ " " ~ rulesRepo ~ " " ~ tmpRulesDir);
        if (cloneCmd.status != 0) {
            writeln("Failed to clone rules repository: ", cloneCmd.output);
            return 1;
        }

        // Guardrail: Look for any SDL rule file in the repo
        bool foundRule = false;
        foreach (DirEntry entry; dirEntries(tmpRulesDir, SpanMode.depth)) {
            if (entry.isFile && entry.name.endsWith(".sdl")) {
                foundRule = true;
                break;
            }
        }

        if (!foundRule) {
            writeln("Guardrail check failed: Repository does not contain any SDL rules.");
            cleanup();
            return 1;
        }
        rulesDir = tmpRulesDir;
    }

    // Always clean up temp rules if they were cloned
    scope(exit) {
        if (rulesRepo != "") cleanup();
    }

    if (domain == "filesystem") {
        if (toVer == "") {
            writeln("Error: --to (context) is required for filesystem domain.");
            return 1;
        }
        string intent = args.length > 1 ? args[1] : "";
        if (intent == "") {
            writeln("Error: intent name required as positional argument.");
            return 1;
        }

        string result = resolveIntent(rulesDir, toVer, intent);
        if (result != "") {
            writeln(intent, " -> ", result);
        } else {
            writeln("Error: Could not resolve intent '", intent, "' for context '", toVer, "'");
            return 1;
        }
        return 0;
    }

    auto engine = new MigrationEngine();
    
    if (fromVer != "" && toVer != "") {
        auto pathFiles = findMigrationPath(rulesDir, fromVer, toVer);
        if (pathFiles.empty) {
            writeln("No migration path found from ", fromVer, " to ", toVer);
            if (rulesRepo != "") cleanup();
            return 1;
        }
        writeln("Migration path: ", fromVer, " -> ", toVer, " using ", pathFiles);
        foreach (f; pathFiles) {
            engine.loadRules(f);
        }
    } else {
        // Fallback to default rule if no versions specified
        string defaultRule = buildPath(rulesDir, "5.15-6.0.sdl");
        if (exists(defaultRule)) {
            engine.loadRules(defaultRule);
        }
    }


    auto extList = extensions.split(",");

    if (!exists(path)) {
        writeln("Path does not exist: ", path);
        return 1;
    }

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

void processFile(string filename, MigrationEngine engine, bool dryRun, string outDir, string baseDir) {
    string content = readText(filename);
    string newContent = engine.applyRules(content);

    if (content != newContent || outDir != "") {
        if (dryRun) {
            writeln("[DRY RUN] ", filename);
        } else if (outDir != "") {
            string relativePath = relativePath(filename, baseDir);
            string targetPath = buildPath(outDir, relativePath);
            string targetDir = dirName(targetPath);
            if (!exists(targetDir)) mkdirRecurse(targetDir);
            std.file.write(targetPath, newContent);
            writeln("Created: ", targetPath);
        } else {
            std.file.write(filename, newContent);
            writeln("Updated: ", filename);
        }
    }
}

string resolveIntent(string rulesDir, string context, string intent) {
    // context: e.g. "linux/ubuntu/22.04"
    auto parts = context.split("/");
    
    // Check local, then default sibling, then up
    while (parts.length > 0) {
        string subPath = parts.join("/");
        string fullPath = buildPath(rulesDir, subPath, intent ~ ".sdl");
        if (exists(fullPath)) return parseIntent(fullPath);
        
        string defaultPath = buildPath(rulesDir, subPath, "default", intent ~ ".sdl");
        if (exists(defaultPath)) return parseIntent(defaultPath);
        
        parts = parts[0 .. $-1];
    }
    
    // Final fallback: root of rulesDir, then rulesDir/default
    string rootPath = buildPath(rulesDir, intent ~ ".sdl");
    if (exists(rootPath)) return parseIntent(rootPath);
    
    string rootDefaultPath = buildPath(rulesDir, "default", intent ~ ".sdl");
    if (exists(rootDefaultPath)) return parseIntent(rootDefaultPath);
    
    return "";
}

string parseIntent(string file) {
    try {
        Tag root = parseFile(file);
        foreach (tag; root.tags) {
            if (tag.name == "mapping" || tag.name == "path" || tag.name == "value") {
                return tag.values[0].get!string;
            }
        }
    } catch (Exception e) {
        writeln("Error parsing intent SDL: ", e.msg);
    }
    return "";
}
