#pragma once
// OrcaPad adapter shim: minimal OCCT type surface so that
// libslic3r/Format/STEP.hpp (unconditionally included by Model.hpp) parses.
// STEP.cpp is NOT compiled in the core subset — declarations only.
// Real STEP support later = real OCCT build; these stubs are then dropped.
#include <string>
#include <vector>

namespace opencascade_stub {
template <typename T>
class HandleImpl {
public:
    HandleImpl() : p(nullptr) {}
    explicit HandleImpl(T *t) : p(t) {}
    HandleImpl(const HandleImpl &) = default;
    HandleImpl &operator=(const HandleImpl &) = default;
    T *get() const { return p; }
    T *operator->() const { return p; }
    operator bool() const { return p != nullptr; }
private:
    T *p;
};
} // namespace opencascade_stub

// OCCT's Handle(Class) macro form
#define Handle(T) opencascade_stub::HandleImpl<T>

using Standard_Boolean = bool;
using Standard_Real = double;
using Standard_Integer = int;

class TopoDS_Shape { public: TopoDS_Shape() = default; };

class TDocStd_Document { public: TDocStd_Document() = default; };
class XCAFDoc_ShapeTool { public: XCAFDoc_ShapeTool() = default; };

class Message_ProgressScope;

class Message_ProgressIndicator {
public:
    virtual ~Message_ProgressIndicator() = default;
    virtual Standard_Boolean UserBreak() { return false; }
    virtual void Show(const Message_ProgressScope &, const Standard_Boolean) {}
    double GetPosition() const { return 0.0; }
};
