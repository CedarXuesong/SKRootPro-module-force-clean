// Read-only SDK module query. Secret input is never accepted via argv.
#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <set>
#include <signal.h>
#include <string>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <termios.h>
#include <tuple>
#include <unistd.h>
#include <vector>
#include "module_err_def.h"
#include "skroot_env/skroot_root.h"
#include "skroot_env/skroot_module.h"
#include "third_party/____DO_NOT_EDIT____/private_skroot_api_runtime_helper.h"

static volatile sig_atomic_t interrupted = 0;
// The reference SDK contains native TLS. Bionic/AArch64 requires 64-byte alignment.
alignas(64) thread_local unsigned char query_tls_anchor[64] __attribute__((used));
static void on_signal(int) { interrupted = 1; }
static bool safe_id(const std::string& text) {
    if (text.empty() || text == "." || text == "..") return false;
    for (unsigned char c : text)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')) return false;
    return true;
}
static bool root_path(const std::string& path) {
    const std::string prefix = "/data/", suffix = "/modules";
    return path.size() > prefix.size() + suffix.size() &&
        path.compare(0, prefix.size(), prefix) == 0 &&
        path.compare(path.size()-suffix.size(), suffix.size(), suffix) == 0 &&
        safe_id(path.substr(prefix.size(), path.size()-prefix.size()-suffix.size()));
}
static bool directory(const std::string& path) {
    struct stat st{};
    if (lstat(path.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) return false;
    char resolved[4096];
    return realpath(path.c_str(), resolved) && path == resolved;
}
static std::string field(const char* text, size_t size) {
    std::string out;
    for (size_t i=0; i<size && text[i]; ++i) {
        unsigned char c = static_cast<unsigned char>(text[i]);
        if (c == '|') out += '/';
        else if (c == '\n' || c == '\r' || c == '\t') out += ' ';
        else if (c >= 32 && c != 127) out += static_cast<char>(c);
    }
    return out;
}
struct Secret {
    char data[128]{};
    Secret() { (void)mlock(data, sizeof(data)); }
    void clear() { volatile char* p = data; for (size_t i=0; i<sizeof(data); ++i) p[i]=0; }
    ~Secret() { clear(); (void)munlock(data, sizeof(data)); }
};
static bool read_secret(Secret& secret, bool from_stdin) {
    // su/command substitution may preserve a PTY on fd 0 without assigning a
    // controlling terminal, making /dev/tty unavailable. Prefer the actual fd.
    int fd = from_stdin ? STDIN_FILENO :
        (isatty(STDIN_FILENO) ? dup(STDIN_FILENO) : open("/dev/tty", O_RDWR | O_CLOEXEC));
    if (fd < 0) { fputs("无法打开终端，请使用 adb shell -t 启动菜单。\n", stderr); return false; }
    termios saved{};
    if (!from_stdin) {
        if (tcgetattr(fd, &saved) != 0) { close(fd); return false; }
        termios hidden = saved;
        hidden.c_lflag &= ~(ECHO | ECHONL);
        if (tcsetattr(fd, TCSAFLUSH, &hidden) != 0) { close(fd); return false; }
        const char prompt[] = "请输入 SKP 密钥（隐藏输入，留空取消）：";
        (void)write(STDERR_FILENO, prompt, sizeof(prompt)-1);
    }
    size_t used = 0;
    bool overflow = false, failed = false;
    for (;;) {
        if (interrupted) { failed = true; break; }
        char c = 0;
        ssize_t count = read(fd, &c, 1);
        if (count <= 0) { if (count < 0) failed = true; break; }
        if (c == '\n' || c == '\r') break;
        if (used + 1 < sizeof(secret.data)) secret.data[used++] = c;
        else overflow = true;
    }
    if (!from_stdin) {
        if (tcsetattr(fd, TCSANOW, &saved) != 0) failed = true;
        (void)write(STDERR_FILENO, "\n", 1);
        close(fd);
    }
    if (failed || overflow || used != 48) {
        fputs("已取消，或密钥格式无效（需要 48 位英文字母/数字）。\n", stderr);
        return false;
    }
    for (size_t i=0; i<used; ++i) {
        unsigned char c = static_cast<unsigned char>(secret.data[i]);
        if (!((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9'))) {
            fputs("密钥格式无效。\n", stderr); return false;
        }
    }
    return true;
}
static const char* state_name(skroot_env::ModuleRunState state) {
    using State = skroot_env::ModuleRunState;
    switch (state) {
        case State::NotRunning: return "未运行";
        case State::Running: return "运行中";
        case State::Abnormal: return "运行异常";
        case State::RemovedPendingReboot: return "已删除，待重启";
    }
    return "未知状态";
}
int main(int argc, char** argv) {
    bool from_stdin = false;
    std::string hint;
    for (int i=1; i<argc; ++i) {
        if (strcmp(argv[i], "--stdin") == 0) from_stdin = true;
        else if (strcmp(argv[i], "--prompt") == 0) from_stdin = false;
        else if (strcmp(argv[i], "--root") == 0 && i+1<argc) hint = argv[++i];
        else { fputs("用法：skp_module_query [--prompt|--stdin] [--root /data/NAME/modules]\n", stderr); return 2; }
    }
    if (!hint.empty() && !root_path(hint)) { fputs("模块目录格式无效。\n", stderr); return 2; }
    rlimit no_core{0, 0};
    (void)setrlimit(RLIMIT_CORE, &no_core);
    (void)prctl(PR_SET_DUMPABLE, 0);
    struct sigaction action{};
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    for (int sig : {SIGINT, SIGTERM, SIGHUP, SIGQUIT}) sigaction(sig, &action, nullptr);
    Secret secret;
    if (!read_secret(secret, from_stdin)) return 3;
    // SDK authentication applies to this short-lived process, not the shell.
    KModErr err = skroot_env::get_root(secret.data);
    if (is_failed(err)) { fprintf(stderr, "SKP 认证失败：%s\n", to_string(err).c_str()); return 4; }
    (void)prctl(PR_SET_DUMPABLE, 0);
    std::vector<skroot_env::module_record> modules;
    err = skroot_env::get_all_modules_list(secret.data, modules);
    if (is_failed(err)) { fprintf(stderr, "SKP 查询失败：%s\n", to_string(err).c_str()); return 5; }
    // SDK skroot_module_list.o: get_system_file_dir_path appends the first
    // character to get_kernel_file_dir_name() (key.substr(0, 16)). Validate the
    // resulting candidate instead of assuming every SDK uses this layout.
    std::string key_root = std::string("/data/") + std::string(secret.data, 16) + secret.data[0] + "/modules";
    secret.clear();

    std::set<std::string> roots;
    if (directory(key_root)) roots.insert(key_root);
    if (!hint.empty() && directory(hint)) roots.insert(hint);
    if (directory("/data/adb/modules")) roots.insert("/data/adb/modules");
    if (DIR* data = opendir("/data")) {
        while (dirent* item = readdir(data)) {
            if (!safe_id(item->d_name)) continue;
            std::string root = std::string("/data/") + item->d_name + "/modules";
            if (directory(root)) roots.insert(root);
        }
        closedir(data);
    }
    for (const auto& item : modules) {
        std::string id = field(item.desc.id32, sizeof(item.desc.id32));
        if (!safe_id(id)) continue;
        std::string root;
        // Prefer supplied root if the exact module directory exists there.
        if (!hint.empty() && directory(hint + "/" + id)) root = hint;
        else for (const auto& candidate : roots)
            if (directory(candidate + "/" + id)) { root = candidate; break; }
        printf("SKP1|MODULE|%s|%s|%s|%s|%s\n", root.c_str(), id.c_str(),
            field(item.desc.name, sizeof(item.desc.name)).c_str(),
            field(item.desc.desc, sizeof(item.desc.desc)).c_str(), state_name(item.state));
    }
    printf("SKP1|DONE|%zu\n", modules.size());
    return 0;
}
