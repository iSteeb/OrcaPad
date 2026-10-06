#pragma once
#include "OCCTStubCore.hxx"
class XCAFApp_Application {
public:
    static Handle(XCAFApp_Application) GetApplication() { return Handle(XCAFApp_Application)(); }
};
