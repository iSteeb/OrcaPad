// OrcaPad adapter: boost::filesystem compiled-lib subset, implemented over
// POSIX + faithful v3 path-string semantics. The cross-build links no
// libboost_filesystem; these are the only symbols the engine archive needs.
// Signatures mirrored from the installed boost headers (operations.hpp /
// path.hpp path_algorithms).
#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/directory.hpp>
#include <boost/filesystem/path.hpp>

#include <cerrno>
#include <cstdio>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace boost {
namespace filesystem {

inline static boost::system::error_code posix_ec() {
    return boost::system::error_code(errno, boost::system::system_category());
}

namespace detail {

// ---- syscalls ----

BOOST_FILESYSTEM_DECL
file_status status(path const &p, boost::system::error_code *ec) {
    if (ec) ec->clear();
    struct stat st;
    if (::stat(p.c_str(), &st) != 0) {
        if (errno == ENOENT || errno == ENOTDIR) {
            if (ec) *ec = posix_ec();
            return file_status(file_not_found);
        }
        if (ec) *ec = posix_ec();
        return file_status(status_error);
    }
    perms pr = static_cast<perms>(st.st_mode & 07777);
    if (S_ISREG(st.st_mode)) return file_status(regular_file, pr);
    if (S_ISDIR(st.st_mode)) return file_status(directory_file, pr);
    if (S_ISLNK(st.st_mode)) return file_status(symlink_file, pr);
    if (S_ISBLK(st.st_mode)) return file_status(block_file, pr);
    if (S_ISCHR(st.st_mode)) return file_status(character_file, pr);
    if (S_ISFIFO(st.st_mode)) return file_status(fifo_file, pr);
    if (S_ISSOCK(st.st_mode)) return file_status(socket_file, pr);
    return file_status(type_unknown, pr);
}

BOOST_FILESYSTEM_DECL
bool create_directory(path const &p, path const *existing, boost::system::error_code *ec) {
    if (ec) ec->clear();
    if (existing) {
        // copy attributes mode best-effort
        struct stat st;
        mode_t mode = 0755;
        if (::stat(existing->c_str(), &st) == 0) mode = st.st_mode & 07777;
        if (::mkdir(p.c_str(), mode) == 0) return true;
    } else if (::mkdir(p.c_str(), 0755) == 0) {
        return true;
    }
    if (errno == EEXIST) {
        boost::system::error_code e;
        return is_directory(p, e);
    }
    if (ec) *ec = posix_ec();
    return false;
}

BOOST_FILESYSTEM_DECL
bool create_directories(path const &p, boost::system::error_code *ec) {
    if (ec) ec->clear();
    if (p.empty()) {
        if (ec) *ec = boost::system::error_code(ENOENT, boost::system::system_category());
        return false;
    }
    boost::system::error_code dummy;
    if (is_directory(p, dummy)) return false;
    path parent = p.parent_path();
    if (!parent.empty() && !exists(parent, dummy))
        create_directories(parent, ec);
    return create_directory(p, static_cast<path const *>(nullptr), ec);
}

BOOST_FILESYSTEM_DECL
boost::uintmax_t remove_all(path const &p, boost::system::error_code *ec) {
    if (ec) ec->clear();
    boost::system::error_code e;
    file_status st = symlink_status(p, e); // lstat semantics via boost
    if (st.type() == file_not_found) return 0;
    if (is_directory(st)) {
        boost::uintmax_t n = 0;
        for (directory_iterator it(p, e), end; !e && it != end; it.increment(e)) {
            n += remove_all(it->path(), ec);
        }
        if (::rmdir(p.c_str()) != 0) {
            if (ec) *ec = posix_ec();
            return n;
        }
        return n + 1;
    }
    if (::remove(p.c_str()) != 0) {
        if (ec) *ec = posix_ec();
        return 0;
    }
    return 1;
}

// ---- path string algorithms (v3 semantics, POSIX separators) ----


BOOST_FILESYSTEM_DECL
void path_algorithms::append_v3(path &p, const path::value_type *b, const path::value_type *e) {
    // Mirror boost: append with separator logic
    if (b != e) {
        path rhs(b, e);
        std::string &s = p.m_pathname;
        bool p_has_slash = !s.empty() && (s.back() == '/' || s.back() == path::preferred_separator);
        bool r_has_slash = !rhs.m_pathname.empty() &&
            (rhs.m_pathname.front() == '/' || rhs.m_pathname.front() == path::preferred_separator);
        bool rhs_root = rhs.m_pathname.size() >= 1 && rhs.m_pathname[0] == '/';
        if (!rhs_root) {
            if (!p_has_slash && !s.empty() && !r_has_slash) s += '/';
            else if (s.empty() && r_has_slash) { /* keep rhs's leading */ }
        } else {
            // absolute rhs replaces
            s.clear();
        }
        s += rhs.m_pathname;
        p.m_pathname = s;
    }
}

BOOST_FILESYSTEM_DECL
path::string_type::size_type path_algorithms::find_parent_path_size(path const &p) {
    const std::string &s = p.native();
    if (s.empty()) return 0;
    auto pos = static_cast<path::string_type::size_type>(s.find_last_of('/'));
    if (pos == std::string::npos) return 0;
    if (pos == 0) return 1; // "/x" -> parent "/"
    // collapse trailing slashes of the parent
    while (pos > 1 && s[pos - 1] == '/') --pos;
    return pos;
}

BOOST_FILESYSTEM_DECL
path path_algorithms::filename_v3(path const &p) {
    const std::string &s = p.native();
    if (s.empty()) return path();
    auto pos = s.find_last_of('/');
    std::string f = (pos == std::string::npos) ? s : s.substr(pos + 1);
    if (f.empty() || f == "." || f == "..") return path();
    return path(f);
}

BOOST_FILESYSTEM_DECL
path path_algorithms::stem_v3(path const &p) {
    std::string f = filename_v3(p).native();
    if (f.empty()) return path();
    size_t pos = f.find_last_of('.');
    if (pos == std::string::npos || pos == 0) return path(f);
    return path(f.substr(0, pos));
}

BOOST_FILESYSTEM_DECL
path path_algorithms::extension_v3(path const &p) {
    std::string f = filename_v3(p).native();
    if (f.empty()) return path();
    size_t pos = f.find_last_of('.');
    if (pos == std::string::npos || pos == 0) return path();
    return path(f.substr(pos));
}

BOOST_FILESYSTEM_DECL
void path_algorithms::replace_extension_v3(path &p, path const &new_ext) {
    std::string s = p.native();
    auto pos = s.find_last_of('/');
    std::string fname = (pos == std::string::npos) ? s : s.substr(pos + 1);
    auto dpos = fname.find_last_of('.');
    std::string base = s.substr(0, (pos == std::string::npos ? 0 : pos + 1) +
                               ((dpos == std::string::npos || dpos == 0) ? fname.size() : dpos));
    std::string ext = new_ext.native();
    if (!ext.empty() && ext.front() != '.') base += '.';
    base += ext;
    p = path(base);
}

} // namespace detail
} // namespace filesystem
} // namespace boost

// ---- filesystem_error: defining the out-of-line members emits vtable +
//      typeinfo (needed by engine exception paths) ----
#include <boost/filesystem/exception.hpp>
#include <boost/smart_ptr/intrusive_ptr.hpp>
#include <cstdlib>
#include <new>

namespace boost {
namespace filesystem {

BOOST_FILESYSTEM_DECL
filesystem_error::filesystem_error(const char *what_arg, boost::system::error_code ec)
    : boost::system::system_error(ec, what_arg) {}

BOOST_FILESYSTEM_DECL
filesystem_error::filesystem_error(std::string const &what_arg, boost::system::error_code ec)
    : boost::system::system_error(ec, what_arg) {}

BOOST_FILESYSTEM_DECL
filesystem_error::filesystem_error(const char *what_arg, path const &p1, boost::system::error_code ec)
    : boost::system::system_error(ec, what_arg) {
    try { m_imp_ptr.reset(new impl(p1, path())); } catch (...) {}
}
BOOST_FILESYSTEM_DECL
filesystem_error::filesystem_error(std::string const &what_arg, path const &p1, boost::system::error_code ec)
    : boost::system::system_error(ec, what_arg) {
    try { m_imp_ptr.reset(new impl(p1, path())); } catch (...) {}
}
BOOST_FILESYSTEM_DECL
filesystem_error::filesystem_error(const char *what_arg, path const &p1, path const &p2, boost::system::error_code ec)
    : boost::system::system_error(ec, what_arg) {
    try { m_imp_ptr.reset(new impl(p1, p2)); } catch (...) {}
}
BOOST_FILESYSTEM_DECL
filesystem_error::filesystem_error(std::string const &what_arg, path const &p1, path const &p2, boost::system::error_code ec)
    : boost::system::system_error(ec, what_arg) {
    try { m_imp_ptr.reset(new impl(p1, p2)); } catch (...) {}
}

BOOST_FILESYSTEM_DECL
filesystem_error::filesystem_error(filesystem_error const &that)
    : boost::system::system_error(static_cast<boost::system::system_error const &>(that)), m_imp_ptr(that.m_imp_ptr) {}

BOOST_FILESYSTEM_DECL
filesystem_error &filesystem_error::operator=(filesystem_error const &that) {
    static_cast<boost::system::system_error &>(*this) = static_cast<boost::system::system_error const &>(that);
    m_imp_ptr = that.m_imp_ptr;
    return *this;
}

BOOST_FILESYSTEM_DECL
filesystem_error::~filesystem_error() noexcept {}

BOOST_FILESYSTEM_DECL
const char *filesystem_error::what() const noexcept {
    if (!m_imp_ptr || (m_imp_ptr->m_path1.empty() && m_imp_ptr->m_path2.empty()))
        return boost::system::system_error::what();
    try {
        m_imp_ptr->m_what = std::string(boost::system::system_error::what());
        if (!m_imp_ptr->m_path1.empty()) {
            m_imp_ptr->m_what += ": \"";
            m_imp_ptr->m_what += m_imp_ptr->m_path1.string();
            m_imp_ptr->m_what += "\"";
        }
        if (!m_imp_ptr->m_path2.empty()) {
            m_imp_ptr->m_what += ", \"";
            m_imp_ptr->m_what += m_imp_ptr->m_path2.string();
            m_imp_ptr->m_what += "\"";
        }
        return m_imp_ptr->m_what.c_str();
    } catch (...) {
        return boost::system::system_error::what();
    }
}

} // namespace filesystem
} // namespace boost

// ---- directory iteration internals (used by remove_all) ----
#include <boost/filesystem/directory.hpp>

namespace boost {
namespace filesystem {
namespace detail {

BOOST_FILESYSTEM_DECL
dir_itr_imp::~dir_itr_imp() noexcept {
    if (handle) ::closedir(static_cast<DIR *>(handle));
}

BOOST_FILESYSTEM_DECL
void *dir_itr_imp::operator new(std::size_t class_size, std::size_t extra_size) noexcept {
    void *mem = std::malloc(class_size + extra_size);
    return mem;
}
BOOST_FILESYSTEM_DECL
void dir_itr_imp::operator delete(void *p, std::size_t) noexcept { std::free(p); }
BOOST_FILESYSTEM_DECL
void dir_itr_imp::operator delete(void *p) noexcept { std::free(p); }

static void dir_itr_read(dir_itr_imp *imp, path const &base) {
    DIR *d = static_cast<DIR *>(imp->handle);
    for (;;) {
        struct dirent *de = ::readdir(d);
        if (!de) { // end of stream
            ::closedir(d);
            imp->handle = nullptr;
            return;
        }
        const char *n = de->d_name;
        if (n[0] == '.' && (n[1] == 0 || (n[1] == '.' && n[2] == 0))) continue; // . ..
        imp->dir_entry.assign(base / n);
        return;
    }
}

BOOST_FILESYSTEM_DECL
void directory_iterator_construct(directory_iterator &it, path const &p,
                                  directory_options, directory_iterator_params *,
                                  boost::system::error_code *ec) {
    if (ec) ec->clear();
    DIR *d = ::opendir(p.c_str());
    if (!d) {
        if (ec) *ec = posix_ec();
        return; // end iterator
    }
    intrusive_ptr<dir_itr_imp> imp(new (0u) dir_itr_imp());
    imp->handle = d;
    dir_itr_read(imp.get(), p);
    if (!imp->handle) return; // empty dir -> end
    it.m_imp = boost::intrusive_ptr<dir_itr_imp>(imp.get());
    imp.detach();
}

BOOST_FILESYSTEM_DECL
void directory_iterator_increment(directory_iterator &it, boost::system::error_code *ec) {
    if (ec) ec->clear();
    if (!it.m_imp) return;
    dir_itr_imp *imp = it.m_imp.get();
    path base = imp->dir_entry.path().parent_path();
    dir_itr_read(imp, base);
    if (!imp->handle) it.m_imp = nullptr; // end
}

BOOST_FILESYSTEM_DECL
file_status symlink_status(path const &p, boost::system::error_code *ec) {
    if (ec) ec->clear();
    struct stat st;
    if (::lstat(p.c_str(), &st) != 0) {
        if (ec) *ec = posix_ec();
        return file_status(file_not_found);
    }
    perms pr = static_cast<perms>(st.st_mode & 07777);
    if (S_ISREG(st.st_mode)) return file_status(regular_file, pr);
    if (S_ISDIR(st.st_mode)) return file_status(directory_file, pr);
    if (S_ISLNK(st.st_mode)) return file_status(symlink_file, pr);
    if (S_ISBLK(st.st_mode)) return file_status(block_file, pr);
    if (S_ISCHR(st.st_mode)) return file_status(character_file, pr);
    if (S_ISFIFO(st.st_mode)) return file_status(fifo_file, pr);
    if (S_ISSOCK(st.st_mode)) return file_status(socket_file, pr);
    return file_status(type_unknown, pr);
}

} // namespace detail
} // namespace filesystem
} // namespace boost
