#include <gdal_priv.h>
#include <ogr_spatialref.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <mutex>
#include <optional>
#include <regex>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace fs = std::filesystem;
constexpr double kPi = 3.14159265358979323846;

struct Config {
    std::string demPath;
    std::string smetTemplatePath;
    std::string snoTemplatePath;
    std::string iniTemplatePath;
    std::string outputRoot;
    std::string snowpackBin = "snowpack";
    std::string idPrefix = "CELL";
    std::optional<std::string> endTime;
    std::optional<double> nodataOverride;
    std::optional<double> minAlt;
    std::optional<double> maxAlt;
    std::size_t maxCells = 0;
    int stride = 1;
    int threads = static_cast<int>(std::thread::hardware_concurrency());
    bool dryRun = false;
    bool keepWorkdirs = false;
    std::string featureColumnsPath = "prediction/feature_columns.json";
    std::string featuresCsvName = "snowpack_features.csv";
    std::optional<double> targetCellSize;
};

struct CellTask {
    int row = 0;
    int col = 0;
    double elevation = 0.0;
    double latitude = 0.0;
    double longitude = 0.0;
    double slopeDeg = 0.0;
    double aspectDeg = 0.0;
};

struct CellResult {
    std::string cellId;
    int row = 0;
    int col = 0;
    double elevation = 0.0;
    double latitude = 0.0;
    double longitude = 0.0;
    double slopeDeg = 0.0;
    double aspectDeg = 0.0;
    std::string status = "NOT_RUN";
    int exitCode = -1;
    double durationSec = 0.0;
    std::unordered_map<std::string, double> features;
};

std::mutex gLogMutex;

std::string toLower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

std::string trim(const std::string& s) {
    const auto begin = s.find_first_not_of(" \t\r\n");
    if (begin == std::string::npos) {
        return "";
    }
    const auto end = s.find_last_not_of(" \t\r\n");
    return s.substr(begin, end - begin + 1);
}

std::string quoteShell(const std::string& raw) {
    std::string out = "'";
    for (char c : raw) {
        if (c == '\'') {
            out += "'\\''";
        } else {
            out.push_back(c);
        }
    }
    out += "'";
    return out;
}

std::string readTextFile(const fs::path& path) {
    std::ifstream in(path);
    if (!in) {
        throw std::runtime_error("Cannot open file: " + path.string());
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

void writeTextFile(const fs::path& path, const std::string& content) {
    std::ofstream out(path);
    if (!out) {
        throw std::runtime_error("Cannot write file: " + path.string());
    }
    out << content;
}

std::string fmtDouble(double value, int precision = 6) {
    std::ostringstream ss;
    ss << std::fixed << std::setprecision(precision) << value;
    return ss.str();
}

std::vector<std::string> splitLines(const std::string& content) {
    std::vector<std::string> lines;
    std::stringstream ss(content);
    std::string line;
    while (std::getline(ss, line)) {
        lines.push_back(line);
    }
    return lines;
}

std::string joinLines(const std::vector<std::string>& lines) {
    std::ostringstream out;
    for (std::size_t i = 0; i < lines.size(); ++i) {
        out << lines[i];
        if (i + 1 < lines.size()) {
            out << '\n';
        }
    }
    return out.str();
}

std::vector<std::string> splitWhitespace(const std::string& line) {
    std::istringstream iss(line);
    std::vector<std::string> out;
    std::string token;
    while (iss >> token) {
        out.push_back(token);
    }
    return out;
}

std::vector<std::string> splitByChar(const std::string& line, char delimiter) {
    std::vector<std::string> out;
    std::string cur;
    std::stringstream ss(line);
    while (std::getline(ss, cur, delimiter)) {
        out.push_back(trim(cur));
    }
    return out;
}

bool isNumber(const std::string& s) {
    if (s.empty()) {
        return false;
    }
    char* endPtr = nullptr;
    (void)std::strtod(s.c_str(), &endPtr);
    return endPtr != s.c_str() && *endPtr == '\0';
}

bool parseDouble(const std::string& s, double& out) {
    try {
        std::size_t idx = 0;
        const double val = std::stod(s, &idx);
        if (idx != s.size()) {
            return false;
        }
        out = val;
        return true;
    } catch (...) {
        return false;
    }
}

void setIniValue(std::vector<std::string>& lines, const std::string& section, const std::string& key, const std::string& value) {
    int sectionStart = -1;
    int sectionEnd = static_cast<int>(lines.size());
    const std::string sectionHeader = "[" + section + "]";
    const std::string wantedSection = toLower(section);

    for (std::size_t i = 0; i < lines.size(); ++i) {
        const std::string t = trim(lines[i]);
        if (!t.empty() && t.front() == '[' && t.back() == ']') {
            const std::string sectionName = toLower(trim(t.substr(1, t.size() - 2)));
            if (sectionName == wantedSection) {
                sectionStart = static_cast<int>(i);
                break;
            }
        }
    }

    if (sectionStart == -1) {
        lines.push_back(sectionHeader);
        lines.push_back(key + " = " + value);
        return;
    }

    for (int i = sectionStart + 1; i < static_cast<int>(lines.size()); ++i) {
        const std::string t = trim(lines[static_cast<std::size_t>(i)]);
        if (!t.empty() && t.front() == '[' && t.back() == ']') {
            sectionEnd = i;
            break;
        }
    }

    for (int i = sectionStart + 1; i < sectionEnd; ++i) {
        const std::string t = trim(lines[static_cast<std::size_t>(i)]);
        const auto eqPos = t.find('=');
        if (eqPos == std::string::npos) {
            continue;
        }
        const std::string k = trim(t.substr(0, eqPos));
        if (toLower(k) == toLower(key)) {
            lines[static_cast<std::size_t>(i)] = key + " = " + value;
            return;
        }
    }

    lines.insert(lines.begin() + sectionEnd, key + " = " + value);
}

void setSmetHeaderValue(std::vector<std::string>& lines, const std::string& key, const std::string& value) {
    int headerStart = -1;
    int headerEnd = static_cast<int>(lines.size());

    for (std::size_t i = 0; i < lines.size(); ++i) {
        if (trim(lines[i]) == "[HEADER]") {
            headerStart = static_cast<int>(i);
            break;
        }
    }

    if (headerStart == -1) {
        throw std::runtime_error("Template is missing [HEADER] section");
    }

    for (int i = headerStart + 1; i < static_cast<int>(lines.size()); ++i) {
        const std::string t = trim(lines[static_cast<std::size_t>(i)]);
        if (!t.empty() && t.front() == '[' && t.back() == ']') {
            headerEnd = i;
            break;
        }
    }

    for (int i = headerStart + 1; i < headerEnd; ++i) {
        const std::string t = trim(lines[static_cast<std::size_t>(i)]);
        const auto eqPos = t.find('=');
        if (eqPos == std::string::npos) {
            continue;
        }
        const std::string k = trim(t.substr(0, eqPos));
        if (toLower(k) == toLower(key)) {
            lines[static_cast<std::size_t>(i)] = key + "       = " + value;
            return;
        }
    }

    lines.insert(lines.begin() + headerEnd, key + "       = " + value);
}

std::optional<std::string> getSmetHeaderValue(const std::vector<std::string>& lines, const std::string& key) {
    int headerStart = -1;
    int headerEnd = static_cast<int>(lines.size());

    for (std::size_t i = 0; i < lines.size(); ++i) {
        if (trim(lines[i]) == "[HEADER]") {
            headerStart = static_cast<int>(i);
            break;
        }
    }
    if (headerStart == -1) {
        return std::nullopt;
    }

    for (int i = headerStart + 1; i < static_cast<int>(lines.size()); ++i) {
        const std::string t = trim(lines[static_cast<std::size_t>(i)]);
        if (!t.empty() && t.front() == '[' && t.back() == ']') {
            headerEnd = i;
            break;
        }
    }

    for (int i = headerStart + 1; i < headerEnd; ++i) {
        const std::string t = trim(lines[static_cast<std::size_t>(i)]);
        const auto eqPos = t.find('=');
        if (eqPos == std::string::npos) {
            continue;
        }
        const std::string k = trim(t.substr(0, eqPos));
        if (toLower(k) == toLower(key)) {
            return trim(t.substr(eqPos + 1));
        }
    }
    return std::nullopt;
}

std::string sanitizeFileStem(std::string v) {
    if (v.empty()) {
        return "station";
    }
    std::string out;
    out.reserve(v.size());
    for (char c : v) {
        const unsigned char uc = static_cast<unsigned char>(c);
        if (std::isalnum(uc) || c == '_' || c == '-') {
            out.push_back(c);
        } else if (std::isspace(uc) || c == '.') {
            out.push_back('_');
        }
    }
    if (out.empty()) {
        out = "station";
    }
    return out;
}

std::string replacePlaceholders(std::string content, const std::unordered_map<std::string, std::string>& values) {
    for (const auto& kv : values) {
        std::string token = "{{" + kv.first + "}}";
        std::size_t pos = 0;
        while ((pos = content.find(token, pos)) != std::string::npos) {
            content.replace(pos, token.size(), kv.second);
            pos += kv.second.size();
        }
    }
    return content;
}

double computeAspect(double dzdx, double dzdy) {
    double aspect = std::atan2(dzdy, -dzdx) * (180.0 / kPi);
    if (aspect < 0.0) {
        aspect = 90.0 - aspect;
    } else if (aspect > 90.0) {
        aspect = 360.0 - aspect + 90.0;
    } else {
        aspect = 90.0 - aspect;
    }
    return aspect;
}

bool isNoData(double value, std::optional<double> nodata) {
    if (std::isnan(value)) {
        return true;
    }
    if (!nodata.has_value()) {
        return false;
    }
    return std::abs(value - nodata.value()) < 1e-8;
}

void printUsage() {
    std::cout
        << "Usage:\n"
        << "  grid_snowpack_service --dem <dem.tif> --smet-template <template.smet>"
        << " --sno-template <template.sno> --ini-template <io.ini>"
        << " --output-root <out_dir> [options]\n\n"
        << "Options:\n"
        << "  --snowpack-bin <path>       Snowpack executable (default: snowpack)\n"
        << "  --threads <n>               Parallel workers (default: CPU count)\n"
        << "  --stride <n>                Process every n-th pixel (default: 1)\n"
        << "  --max-cells <n>             Stop after n valid cells (default: all)\n"
        << "  --id-prefix <prefix>        Cell ID prefix (default: CELL)\n"
        << "  --end-time <ISO8601>        Passed to snowpack -e\n"
        << "  --nodata <value>            Override DEM nodata value\n"
        << "  --min-alt <m>               Filter out cells below altitude\n"
        << "  --max-alt <m>               Filter out cells above altitude\n"
        << "  --feature-columns <path>    Feature columns JSON (default: prediction/feature_columns.json)\n"
        << "  --features-csv <name>       CSV filename under output root (default: snowpack_features.csv)\n"
        << "  --cell-size <meters>        Target cell size in meters (resamples DEM if needed)\n"
        << "  --keep-workdirs             Keep per-thread temporary Snowpack workdirs\n"
        << "  --dry-run                   Generate inputs but skip Snowpack execution\n"
        << "  --help                      Show this message\n";
}

Config parseArgs(int argc, char** argv) {
    Config cfg;

    auto requireValue = [&](int i, const std::string& flag) {
        if (i + 1 >= argc) {
            throw std::runtime_error("Missing value for " + flag);
        }
    };

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--help") {
            printUsage();
            std::exit(0);
        } else if (arg == "--dem") {
            requireValue(i, arg);
            cfg.demPath = argv[++i];
        } else if (arg == "--smet-template") {
            requireValue(i, arg);
            cfg.smetTemplatePath = argv[++i];
        } else if (arg == "--sno-template") {
            requireValue(i, arg);
            cfg.snoTemplatePath = argv[++i];
        } else if (arg == "--ini-template") {
            requireValue(i, arg);
            cfg.iniTemplatePath = argv[++i];
        } else if (arg == "--output-root") {
            requireValue(i, arg);
            cfg.outputRoot = argv[++i];
        } else if (arg == "--snowpack-bin") {
            requireValue(i, arg);
            cfg.snowpackBin = argv[++i];
        } else if (arg == "--threads") {
            requireValue(i, arg);
            cfg.threads = std::max(1, std::stoi(argv[++i]));
        } else if (arg == "--stride") {
            requireValue(i, arg);
            cfg.stride = std::max(1, std::stoi(argv[++i]));
        } else if (arg == "--max-cells") {
            requireValue(i, arg);
            cfg.maxCells = static_cast<std::size_t>(std::stoull(argv[++i]));
        } else if (arg == "--id-prefix") {
            requireValue(i, arg);
            cfg.idPrefix = argv[++i];
        } else if (arg == "--end-time") {
            requireValue(i, arg);
            cfg.endTime = std::string(argv[++i]);
        } else if (arg == "--nodata") {
            requireValue(i, arg);
            cfg.nodataOverride = std::stod(argv[++i]);
        } else if (arg == "--min-alt") {
            requireValue(i, arg);
            cfg.minAlt = std::stod(argv[++i]);
        } else if (arg == "--max-alt") {
            requireValue(i, arg);
            cfg.maxAlt = std::stod(argv[++i]);
        } else if (arg == "--feature-columns") {
            requireValue(i, arg);
            cfg.featureColumnsPath = argv[++i];
        } else if (arg == "--features-csv") {
            requireValue(i, arg);
            cfg.featuresCsvName = argv[++i];
        } else if (arg == "--cell-size") {
            requireValue(i, arg);
            cfg.targetCellSize = std::stod(argv[++i]);
        } else if (arg == "--keep-workdirs") {
            cfg.keepWorkdirs = true;
        } else if (arg == "--dry-run") {
            cfg.dryRun = true;
        } else {
            throw std::runtime_error("Unknown argument: " + arg);
        }
    }

    if (cfg.demPath.empty() || cfg.smetTemplatePath.empty() || cfg.snoTemplatePath.empty() ||
        cfg.iniTemplatePath.empty() || cfg.outputRoot.empty()) {
        throw std::runtime_error("Missing required arguments. Use --help for usage.");
    }

    if (cfg.threads <= 0) {
        cfg.threads = 1;
    }
    return cfg;
}

std::vector<std::string> loadFeatureColumns(const fs::path& path) {
    const std::string content = readTextFile(path);
    std::regex quotedString("\"([^\"]+)\"");
    std::sregex_iterator it(content.begin(), content.end(), quotedString);
    std::sregex_iterator end;

    std::vector<std::string> ordered;
    std::unordered_set<std::string> seen;
    for (; it != end; ++it) {
        const std::string key = (*it)[1].str();
        if (seen.insert(key).second) {
            ordered.push_back(key);
        }
    }

    if (ordered.empty()) {
        throw std::runtime_error("No feature columns found in: " + path.string());
    }
    return ordered;
}

std::unordered_map<std::string, double> parseSmetLastValues(const fs::path& smetPath) {
    std::ifstream in(smetPath);
    if (!in) {
        throw std::runtime_error("Cannot open SMET: " + smetPath.string());
    }

    std::vector<std::string> fields;
    std::string lastDataLine;
    bool inData = false;

    std::string line;
    while (std::getline(in, line)) {
        const std::string t = trim(line);
        if (t.empty()) {
            continue;
        }

        if (toLower(t).rfind("fields", 0) == 0) {
            const auto eq = t.find('=');
            if (eq != std::string::npos) {
                fields = splitWhitespace(trim(t.substr(eq + 1)));
            }
            continue;
        }

        if (t == "[DATA]") {
            inData = true;
            continue;
        }

        if (inData) {
            lastDataLine = t;
        }
    }

    std::unordered_map<std::string, double> out;
    if (fields.empty() || lastDataLine.empty()) {
        return out;
    }

    const std::vector<std::string> values = splitWhitespace(lastDataLine);
    const std::size_t n = std::min(fields.size(), values.size());
    for (std::size_t i = 0; i < n; ++i) {
        const std::string key = toLower(fields[i]);
        if (key == "timestamp") {
            continue;
        }
        double v = 0.0;
        if (parseDouble(values[i], v) && v != -999.0) {
            out[key] = v;
        }
    }

    return out;
}

std::optional<double> getFeature(const std::unordered_map<std::string, double>& m, const std::string& key) {
    const auto it = m.find(toLower(key));
    if (it == m.end()) {
        return std::nullopt;
    }
    return it->second;
}

void parseProFeatures(const fs::path& proPath, std::unordered_map<std::string, double>& features) {
    std::ifstream in(proPath);
    if (!in) {
        return;
    }

    const std::unordered_map<std::string, std::string> searchMap = {
        {"sk38", "sk38"},
        {"sn38", "sn38"},
        {"ccl", "critical cut length"},
        {"ts_elements", "element temperature"},
    };

    std::unordered_map<std::string, std::string> codes;
    std::unordered_map<std::string, std::vector<double>> data;
    for (const auto& kv : searchMap) {
        codes[kv.first] = "";
        data[kv.first] = {};
    }

    std::string line;
    while (std::getline(in, line)) {
        const std::vector<std::string> parts = splitByChar(line, ',');
        if (parts.empty()) {
            continue;
        }
        const std::string lower = toLower(line);

        if (parts.size() > 1 && isNumber(parts[0]) && !isNumber(parts[1])) {
            for (const auto& kv : searchMap) {
                if (codes[kv.first].empty() && lower.find(kv.second) != std::string::npos) {
                    codes[kv.first] = parts[0];
                }
            }
        }

        if (parts.size() > 2 && isNumber(parts[0])) {
            for (const auto& kv : codes) {
                if (!kv.second.empty() && parts[0] == kv.second) {
                    for (std::size_t i = 2; i < parts.size(); ++i) {
                        double v = 0.0;
                        if (parseDouble(parts[i], v) && v != -999.0) {
                            data[kv.first].push_back(v);
                        }
                    }
                }
            }
        }
    }

    auto minPositiveOr = [](const std::vector<double>& vals, double fallback) {
        double best = std::numeric_limits<double>::max();
        for (double v : vals) {
            if (v > 0.0 && v < best) {
                best = v;
            }
        }
        return (best == std::numeric_limits<double>::max()) ? fallback : best;
    };

    features["sk38_pwl"] = minPositiveOr(data["sk38"], 6.0);
    features["sn38_pwl"] = minPositiveOr(data["sn38"], 6.0);
    features["ccl_pwl"] = minPositiveOr(data["ccl"], 3.0);

    const std::vector<double>& temps = data["ts_elements"];
    features["ts1"] = temps.empty() ? -5.0 : temps.back();
    features["ts2"] = temps.empty() ? -2.0 : temps[temps.size() / 2];
}

void extractFeatureSet(const fs::path& outSmetPath, const fs::path& inputSmetPath, const fs::path& outProPath,
                       std::unordered_map<std::string, double>& features) {
    const std::unordered_map<std::string, double> outMap = parseSmetLastValues(outSmetPath);
    const std::unordered_map<std::string, double> inMap = parseSmetLastValues(inputSmetPath);

    auto assignFromMap = [&](const std::string& target, const std::string& source) {
        const auto outVal = getFeature(outMap, source);
        if (outVal.has_value()) {
            features[toLower(target)] = outVal.value();
        }
    };

    assignFromMap("SWE", "SWE");
    assignFromMap("MS_Snow", "MS_Snow");
    assignFromMap("Pen_depth", "ski_pen");
    assignFromMap("HN24", "HN24");
    assignFromMap("HN72_24", "HN72_24");
    assignFromMap("wind_trans24", "wind_trans24");
    assignFromMap("pAlbedo", "pAlbedo");
    assignFromMap("Qw", "Qw");
    assignFromMap("LWR_net", "LWR_net");
    assignFromMap("ILWR", "ILWR");
    assignFromMap("S4", "S4");
    assignFromMap("Sn", "Sn");
    assignFromMap("Sd", "Sd");

    if (const auto hn168 = getFeature(outMap, "HN168"); hn168.has_value()) {
        features["hn24_7d"] = hn168.value();
    }
    if (const auto wt72 = getFeature(outMap, "WIND_TRANS72"); wt72.has_value()) {
        features["wind_trans24_3d"] = wt72.value();
    }
    if (const auto pen = getFeature(outMap, "ski_pen"); pen.has_value()) {
        features["min_ccl_pen"] = pen.value();
    }

    auto assignMeteo = [&](const std::string& keyOut, const std::string& keyIn) {
        if (const auto v = getFeature(outMap, keyOut); v.has_value()) {
            features[toLower(keyOut)] = v.value();
            return;
        }
        if (const auto v = getFeature(inMap, keyIn); v.has_value()) {
            features[toLower(keyOut)] = v.value();
        }
    };

    assignMeteo("TA", "TA");
    assignMeteo("RH", "RH");
    assignMeteo("VW", "VW");
    assignMeteo("DW", "DW");
    assignMeteo("ISWR", "ISWR");
    assignMeteo("TSG", "TSG");

    if (const auto hs = getFeature(outMap, "HS"); hs.has_value()) {
        features["hs_meas"] = hs.value();
    } else if (const auto hs = getFeature(inMap, "HS"); hs.has_value()) {
        features["hs_meas"] = hs.value();
    }

    parseProFeatures(outProPath, features);
}

fs::path findFirstFile(const fs::path& dir, const std::string& suffix) {
    for (const auto& entry : fs::directory_iterator(dir)) {
        if (!entry.is_regular_file()) {
            continue;
        }
        if (entry.path().extension() == suffix) {
            return entry.path();
        }
    }
    return {};
}

int runSnowpack(const fs::path& workDir, const std::string& snowpackBin, const std::optional<std::string>& endTime) {
    std::ostringstream cmd;
    cmd << "cd " << quoteShell(workDir.string()) << " && " << quoteShell(snowpackBin) << " -c cfgfiles/io.ini";
    if (endTime.has_value()) {
        cmd << " -e " << quoteShell(endTime.value());
    }
    return std::system(cmd.str().c_str());
}

std::string toCsvCell(const std::string& s) {
    std::string out = "\"";
    for (char c : s) {
        if (c == '\"') {
            out += "\"\"";
        } else {
            out.push_back(c);
        }
    }
    out += "\"";
    return out;
}

std::vector<double> resampleDem(const std::vector<double>& dem, int inWidth, int inHeight,
                                 double gt[6], double targetCellSize,
                                 int& outWidth, int& outHeight) {
    const double currentCellSizeX = std::sqrt(gt[1] * gt[1] + gt[4] * gt[4]);
    const double scaleFactor = currentCellSizeX / targetCellSize;
    if (std::abs(scaleFactor - 1.0) < 1e-6) {
        outWidth = inWidth;
        outHeight = inHeight;
        return dem;
    }

    outWidth = static_cast<int>(inWidth * scaleFactor);
    outHeight = static_cast<int>(inHeight * scaleFactor);
    if (outWidth < 3 || outHeight < 3) {
        outWidth = inWidth;
        outHeight = inHeight;
        return dem;
    }

    std::vector<double> resampled(static_cast<std::size_t>(outWidth) * static_cast<std::size_t>(outHeight));
    for (int y = 0; y < outHeight; ++y) {
        for (int x = 0; x < outWidth; ++x) {
            const double srcX = x / scaleFactor;
            const double srcY = y / scaleFactor;
            const int sx = static_cast<int>(srcX);
            const int sy = static_cast<int>(srcY);

            if (sx >= inWidth - 1 || sy >= inHeight - 1) {
                resampled[static_cast<std::size_t>(y) * static_cast<std::size_t>(outWidth) + static_cast<std::size_t>(x)] = dem[static_cast<std::size_t>(sy) * static_cast<std::size_t>(inWidth) + static_cast<std::size_t>(sx)];
            } else {
                const double fx = srcX - sx;
                const double fy = srcY - sy;
                const double v00 = dem[static_cast<std::size_t>(sy) * static_cast<std::size_t>(inWidth) + static_cast<std::size_t>(sx)];
                const double v10 = dem[static_cast<std::size_t>(sy) * static_cast<std::size_t>(inWidth) + static_cast<std::size_t>(sx + 1)];
                const double v01 = dem[static_cast<std::size_t>(sy + 1) * static_cast<std::size_t>(inWidth) + static_cast<std::size_t>(sx)];
                const double v11 = dem[static_cast<std::size_t>(sy + 1) * static_cast<std::size_t>(inWidth) + static_cast<std::size_t>(sx + 1)];

                const double v0 = v00 * (1.0 - fx) + v10 * fx;
                const double v1 = v01 * (1.0 - fx) + v11 * fx;
                const double v = v0 * (1.0 - fy) + v1 * fy;
                resampled[static_cast<std::size_t>(y) * static_cast<std::size_t>(outWidth) + static_cast<std::size_t>(x)] = v;
            }
        }
    }

    // Pixel vectors need to grow when dimensions shrink and vice-versa.
    gt[1] /= scaleFactor;
    gt[2] /= scaleFactor;
    gt[4] /= scaleFactor;
    gt[5] /= scaleFactor;

    return resampled;
}

int main(int argc, char** argv) {
    try {
        Config cfg = parseArgs(argc, argv);
        GDALAllRegister();

        const std::string smetTemplate = readTextFile(cfg.smetTemplatePath);
        const std::string snoTemplate = readTextFile(cfg.snoTemplatePath);
        const std::string iniTemplate = readTextFile(cfg.iniTemplatePath);
        const std::vector<std::string> featureColumns = loadFeatureColumns(cfg.featureColumnsPath);
        const std::vector<std::string> smetTemplateLines = splitLines(smetTemplate);
        const std::string templateStationId = getSmetHeaderValue(smetTemplateLines, "station_id").value_or("STATION");
        const std::string templateStationName = getSmetHeaderValue(smetTemplateLines, "station_name").value_or(templateStationId);
        const std::string templateStationAbbr = getSmetHeaderValue(smetTemplateLines, "station_abbr").value_or(templateStationId);
        const std::string stationFileStem = sanitizeFileStem(templateStationAbbr.empty() ? templateStationId : templateStationAbbr);

        std::unique_ptr<GDALDataset, void (*)(GDALDataset*)> ds(
            static_cast<GDALDataset*>(GDALOpen(cfg.demPath.c_str(), GA_ReadOnly)),
            [](GDALDataset* d) {
                if (d) {
                    GDALClose(d);
                }
            });

        if (!ds) {
            throw std::runtime_error("Failed to open DEM: " + cfg.demPath);
        }

        int width = ds->GetRasterXSize();
        int height = ds->GetRasterYSize();
        if (width < 3 || height < 3) {
            throw std::runtime_error("DEM must be at least 3x3 to compute slope/aspect.");
        }

        GDALRasterBand* band = ds->GetRasterBand(1);
        if (!band) {
            throw std::runtime_error("DEM band 1 is unavailable.");
        }

        int hasBandNoData = 0;
        const double bandNoData = band->GetNoDataValue(&hasBandNoData);
        std::optional<double> nodata = cfg.nodataOverride;
        if (!nodata.has_value() && hasBandNoData) {
            nodata = bandNoData;
        }

        double gt[6] = {0, 0, 0, 0, 0, 0};
        if (ds->GetGeoTransform(gt) != CE_None) {
            throw std::runtime_error("DEM is missing geotransform metadata.");
        }

    std::vector<double> dem(static_cast<std::size_t>(width) * static_cast<std::size_t>(height));
        if (band->RasterIO(
                GF_Read,
                0,
                0,
                width,
                height,
                dem.data(),
                width,
                height,
                GDT_Float64,
                0,
                0) != CE_None) {
            throw std::runtime_error("Failed to read DEM raster data.");
        }

        if (cfg.targetCellSize.has_value()) {
            int resampledWidth = 0;
            int resampledHeight = 0;
            dem = resampleDem(dem, width, height, gt, cfg.targetCellSize.value(), resampledWidth, resampledHeight);
            width = resampledWidth;
            height = resampledHeight;
        }

        const double cellSizeXFinal = std::sqrt(gt[1] * gt[1] + gt[4] * gt[4]);
        const double cellSizeYFinal = std::sqrt(gt[2] * gt[2] + gt[5] * gt[5]);
        const double denomX = 8.0 * std::max(1e-9, cellSizeXFinal);
        const double denomY = 8.0 * std::max(1e-9, cellSizeYFinal);

        OGRSpatialReference srcSrs;
        const char* proj = ds->GetProjectionRef();
        if (!proj || std::string(proj).empty()) {
            throw std::runtime_error("DEM projection is missing; cannot compute lat/lon.");
        }
        if (srcSrs.importFromWkt(proj) != OGRERR_NONE) {
            throw std::runtime_error("Failed to parse DEM projection WKT.");
        }

        OGRSpatialReference wgs84;
        wgs84.SetWellKnownGeogCS("WGS84");
        OGRCoordinateTransformation* rawTx = OGRCreateCoordinateTransformation(&srcSrs, &wgs84);
        std::unique_ptr<OGRCoordinateTransformation, decltype(&OCTDestroyCoordinateTransformation)> tx(
            rawTx,
            OCTDestroyCoordinateTransformation);
        if (!tx) {
            throw std::runtime_error("Failed to create coordinate transformer to WGS84.");
        }

        std::vector<CellTask> tasks;
        tasks.reserve(static_cast<std::size_t>(width) * static_cast<std::size_t>(height) / static_cast<std::size_t>(cfg.stride * cfg.stride));

        bool stop = false;
        for (int row = 1; row < height - 1 && !stop; row += cfg.stride) {
            for (int col = 1; col < width - 1; col += cfg.stride) {
                const std::size_t idx = static_cast<std::size_t>(row) * static_cast<std::size_t>(width) + static_cast<std::size_t>(col);
                const double z = dem[idx];
                if (isNoData(z, nodata)) {
                    continue;
                }
                if (cfg.minAlt.has_value() && z < cfg.minAlt.value()) {
                    continue;
                }
                if (cfg.maxAlt.has_value() && z > cfg.maxAlt.value()) {
                    continue;
                }

                const double z1 = dem[static_cast<std::size_t>(row - 1) * static_cast<std::size_t>(width) + static_cast<std::size_t>(col - 1)];
                const double z2 = dem[static_cast<std::size_t>(row - 1) * static_cast<std::size_t>(width) + static_cast<std::size_t>(col)];
                const double z3 = dem[static_cast<std::size_t>(row - 1) * static_cast<std::size_t>(width) + static_cast<std::size_t>(col + 1)];
                const double z4 = dem[static_cast<std::size_t>(row) * static_cast<std::size_t>(width) + static_cast<std::size_t>(col - 1)];
                const double z6 = dem[static_cast<std::size_t>(row) * static_cast<std::size_t>(width) + static_cast<std::size_t>(col + 1)];
                const double z7 = dem[static_cast<std::size_t>(row + 1) * static_cast<std::size_t>(width) + static_cast<std::size_t>(col - 1)];
                const double z8 = dem[static_cast<std::size_t>(row + 1) * static_cast<std::size_t>(width) + static_cast<std::size_t>(col)];
                const double z9 = dem[static_cast<std::size_t>(row + 1) * static_cast<std::size_t>(width) + static_cast<std::size_t>(col + 1)];

                if (isNoData(z1, nodata) || isNoData(z2, nodata) || isNoData(z3, nodata) || isNoData(z4, nodata) ||
                    isNoData(z6, nodata) || isNoData(z7, nodata) || isNoData(z8, nodata) || isNoData(z9, nodata)) {
                    continue;
                }

                const double dzdx = ((z3 + 2.0 * z6 + z9) - (z1 + 2.0 * z4 + z7)) / denomX;
                const double dzdy = ((z7 + 2.0 * z8 + z9) - (z1 + 2.0 * z2 + z3)) / denomY;
                const double slopeDeg = std::atan(std::sqrt(dzdx * dzdx + dzdy * dzdy)) * (180.0 / kPi);
                const double aspectDeg = computeAspect(dzdx, dzdy);

                double x = gt[0] + (static_cast<double>(col) + 0.5) * gt[1] + (static_cast<double>(row) + 0.5) * gt[2];
                double y = gt[3] + (static_cast<double>(col) + 0.5) * gt[4] + (static_cast<double>(row) + 0.5) * gt[5];
                double zc = 0.0;
                if (!tx->Transform(1, &x, &y, &zc)) {
                    continue;
                }

                CellTask t;
                t.row = row;
                t.col = col;
                t.elevation = z;
                t.longitude = x;
                t.latitude = y;
                t.slopeDeg = slopeDeg;
                t.aspectDeg = aspectDeg;
                tasks.push_back(t);

                if (cfg.maxCells > 0 && tasks.size() >= cfg.maxCells) {
                    stop = true;
                    break;
                }
            }
        }

        fs::create_directories(cfg.outputRoot);
        const fs::path workRoot = fs::path(cfg.outputRoot) / "workdirs";
        fs::create_directories(workRoot);

        {
            std::lock_guard<std::mutex> lock(gLogMutex);
            std::cout << "Prepared " << tasks.size() << " valid cell jobs from DEM " << width << "x" << height
                      << " (stride=" << cfg.stride << ", threads=" << cfg.threads << ")" << std::endl;
        }

        std::vector<CellResult> results(tasks.size());
        std::atomic<std::size_t> nextIndex{0};

        auto worker = [&](int workerId) {
            const fs::path workerDir = workRoot / ("worker_" + std::to_string(workerId));
            const fs::path inputDir = workerDir / "input";
            const fs::path cfgDir = workerDir / "cfgfiles";
            const fs::path outDir = workerDir / "output";
            fs::create_directories(inputDir);
            fs::create_directories(cfgDir);
            fs::create_directories(outDir);

            while (true) {
                const std::size_t i = nextIndex.fetch_add(1);
                if (i >= tasks.size()) {
                    break;
                }

                const CellTask& t = tasks[i];
                CellResult r;
                r.row = t.row;
                r.col = t.col;
                r.elevation = t.elevation;
                r.latitude = t.latitude;
                r.longitude = t.longitude;
                r.slopeDeg = t.slopeDeg;
                r.aspectDeg = t.aspectDeg;

                std::ostringstream id;
                id << cfg.idPrefix << "_r" << t.row << "_c" << t.col;
                r.cellId = id.str();
                const std::string stationSmetFile = stationFileStem + ".smet";
                const std::string stationSnoFile = stationFileStem + ".sno";

                const auto t0 = std::chrono::steady_clock::now();
                try {
                    const std::unordered_map<std::string, std::string> ph = {
                        {"STATION_ID", templateStationId},
                        {"STATION_NAME", templateStationName},
                        {"STATION_ABBR", templateStationAbbr},
                        {"LATITUDE", fmtDouble(r.latitude, 6)},
                        {"LONGITUDE", fmtDouble(r.longitude, 6)},
                        {"ALTITUDE", fmtDouble(r.elevation, 2)},
                        {"SLOPE_ANGLE", fmtDouble(r.slopeDeg, 2)},
                        {"SLOPE_AZI", fmtDouble(r.aspectDeg, 2)},
                        {"STATION_SMET_FILENAME", stationSmetFile},
                        {"METEOPATH", "./input"},
                        {"SNOWPATH", "./input"},
                        {"OUTPUTPATH", "./output"},
                        {"EXPERIMENT", "GRID"},
                    };

                    std::string smetContent = replacePlaceholders(smetTemplate, ph);
                    std::vector<std::string> smetLines = splitLines(smetContent);
                    setSmetHeaderValue(smetLines, "station_id", templateStationId);
                    setSmetHeaderValue(smetLines, "station_name", templateStationName);
                    setSmetHeaderValue(smetLines, "station_abbr", templateStationAbbr);
                    setSmetHeaderValue(smetLines, "latitude", fmtDouble(r.latitude, 6));
                    setSmetHeaderValue(smetLines, "longitude", fmtDouble(r.longitude, 6));
                    setSmetHeaderValue(smetLines, "altitude", fmtDouble(r.elevation, 2));
                    smetContent = joinLines(smetLines);
                    writeTextFile(inputDir / stationSmetFile, smetContent);

                    std::string snoContent = replacePlaceholders(snoTemplate, ph);
                    std::vector<std::string> snoLines = splitLines(snoContent);
                    setSmetHeaderValue(snoLines, "station_id", templateStationId);
                    setSmetHeaderValue(snoLines, "station_name", templateStationName);
                    setSmetHeaderValue(snoLines, "station_abbr", templateStationAbbr);
                    setSmetHeaderValue(snoLines, "latitude", fmtDouble(r.latitude, 6));
                    setSmetHeaderValue(snoLines, "longitude", fmtDouble(r.longitude, 6));
                    setSmetHeaderValue(snoLines, "altitude", fmtDouble(r.elevation, 2));
                    setSmetHeaderValue(snoLines, "SlopeAngle", fmtDouble(r.slopeDeg, 2));
                    setSmetHeaderValue(snoLines, "SlopeAzi", fmtDouble(r.aspectDeg, 2));
                    snoContent = joinLines(snoLines);
                    writeTextFile(inputDir / stationSnoFile, snoContent);

                    std::string iniContent = replacePlaceholders(iniTemplate, ph);
                    std::vector<std::string> iniLines = splitLines(iniContent);
                    setIniValue(iniLines, "INPUT", "METEOPATH", "./input");
                    setIniValue(iniLines, "INPUT", "SNOWPATH", "./input");
                    setIniValue(iniLines, "INPUT", "STATION1", stationSmetFile);
                    setIniValue(iniLines, "OUTPUT", "METEOPATH", "./output");
                    setIniValue(iniLines, "OUTPUT", "EXPERIMENT", "GRID");
                    iniContent = joinLines(iniLines);
                    writeTextFile(cfgDir / "io.ini", iniContent);

                    if (cfg.dryRun) {
                        r.status = "DRY_RUN";
                        r.exitCode = 0;
                    } else {
                        const int rc = runSnowpack(workerDir, cfg.snowpackBin, cfg.endTime);
                        r.exitCode = rc;
                        r.status = (rc == 0) ? "OK" : "FAILED";
                        if (rc == 0) {
                            fs::path outSmet = outDir / (templateStationId + "_GRID.smet");
                            fs::path outPro = outDir / (templateStationId + "_GRID.pro");
                            if (!fs::exists(outSmet)) {
                                outSmet = findFirstFile(outDir, ".smet");
                            }
                            if (!fs::exists(outPro)) {
                                outPro = findFirstFile(outDir, ".pro");
                            }

                            if (!outSmet.empty() && fs::exists(outSmet)) {
                                extractFeatureSet(outSmet, inputDir / stationSmetFile, outPro, r.features);
                            }
                        }
                    }
                } catch (const std::exception& ex) {
                    r.status = std::string("ERROR: ") + ex.what();
                    r.exitCode = -1;
                }

                const auto t1 = std::chrono::steady_clock::now();
                r.durationSec = std::chrono::duration<double>(t1 - t0).count();
                results[i] = std::move(r);

                if ((i + 1) % 100 == 0 || i + 1 == tasks.size()) {
                    std::lock_guard<std::mutex> lock(gLogMutex);
                    std::cout << "Completed " << (i + 1) << "/" << tasks.size() << " jobs" << std::endl;
                }
            }
        };

        std::vector<std::thread> pool;
        pool.reserve(static_cast<std::size_t>(cfg.threads));
        for (int i = 0; i < cfg.threads; ++i) {
            pool.emplace_back(worker, i);
        }
        for (auto& th : pool) {
            th.join();
        }

        const fs::path csvPath = fs::path(cfg.outputRoot) / cfg.featuresCsvName;
        std::ofstream csv(csvPath);
        if (!csv) {
            throw std::runtime_error("Cannot write CSV: " + csvPath.string());
        }

        csv << "cell_id,row,col,altitude,latitude,longitude,slope_angle,slope_azi,status,exit_code,duration_sec";
        for (const std::string& f : featureColumns) {
            csv << ',' << f;
        }
        csv << '\n';

        std::size_t ok = 0;
        std::size_t failed = 0;
        for (const auto& r : results) {
            csv << toCsvCell(r.cellId) << ',' << r.row << ',' << r.col << ','
                << std::fixed << std::setprecision(2) << r.elevation << ','
                << std::setprecision(6) << r.latitude << ',' << r.longitude << ','
                << std::setprecision(2) << r.slopeDeg << ',' << r.aspectDeg << ','
                << toCsvCell(r.status) << ',' << r.exitCode << ',' << std::setprecision(3) << r.durationSec;

            for (const std::string& f : featureColumns) {
                const auto it = r.features.find(toLower(f));
                if (it != r.features.end()) {
                    csv << ',' << std::setprecision(6) << it->second;
                } else {
                    csv << ',';
                }
            }
            csv << '\n';

            if (r.status == "OK" || r.status == "DRY_RUN") {
                ++ok;
            } else {
                ++failed;
            }
        }

        if (!cfg.keepWorkdirs) {
            fs::remove_all(workRoot);
        }

        std::cout << "Run complete. OK=" << ok << " FAILED=" << failed << " CSV=" << csvPath.string() << std::endl;
        return failed == 0 ? 0 : 2;
    } catch (const std::exception& ex) {
        std::cerr << "Fatal error: " << ex.what() << std::endl;
        return 1;
    }
}
