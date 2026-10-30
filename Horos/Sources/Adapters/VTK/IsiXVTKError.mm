//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXVTKInternal.hpp"

#include <vtkCallbackCommand.h>
#include <vtkCommand.h>
#include <vtkObject.h>

NSErrorDomain const IsiXVTKErrorDomain = @"IsiXVTKErrorDomain";
NSString * const IsiXVTKOperationKey = @"IsiXVTKOperation";
NSString * const IsiXVTKMessageKey = @"IsiXVTKMessage";
NSString * const IsiXVTKClassKey = @"IsiXVTKClass";

static NSString *IsiXVTKString(const char *text)
{
    return [NSString stringWithUTF8String:text ?: ""] ?: @"";
}

NSError *IsiXVTKErrorFromException(const char *what, const char *operation)
{
    NSString *reason = IsiXVTKString(what), *call = IsiXVTKString(operation);
    NSLog(@"---- VTK adapter: %@ threw a C++ exception: %@", call, reason);
    return [NSError errorWithDomain:IsiXVTKErrorDomain code:IsiXVTKErrorCodeException userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", call, reason],
        IsiXVTKOperationKey: call,
        IsiXVTKMessageKey: reason,
    }];
}

NSError *IsiXVTKErrorFromLibrary(const char *message, const char *className, const char *operation)
{
    NSString *text = [IsiXVTKString(message) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *call = IsiXVTKString(operation), *type = IsiXVTKString(className);
    return [NSError errorWithDomain:IsiXVTKErrorDomain code:IsiXVTKErrorCodeLibrary userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", call, text],
        IsiXVTKOperationKey: call,
        IsiXVTKMessageKey: text,
        IsiXVTKClassKey: type,
    }];
}

NSError *IsiXVTKFailure(IsiXVTKErrorCode code, NSString *description, const char *operation)
{
    NSString *call = IsiXVTKString(operation);
    return [NSError errorWithDomain:IsiXVTKErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: description,
        IsiXVTKOperationKey: call,
    }];
}

IsiXVTKErrorCapture::IsiXVTKErrorCapture(std::initializer_list<vtkObject *> objects, const char *operation)
    : Operation(operation)
{
    for (vtkObject *object : objects) {
        if (!object) continue;
        vtkCallbackCommand *command = vtkCallbackCommand::New();
        command->SetClientData(this);
        command->SetCallback([](vtkObject *caller, unsigned long, void *context, void *message) {
            static_cast<IsiXVTKErrorCapture *>(context)->Report(caller, static_cast<const char *>(message));
        });
        this->Observers.emplace_back(object, object->AddObserver(vtkCommand::ErrorEvent, command));
        command->Delete();
    }
}

IsiXVTKErrorCapture::~IsiXVTKErrorCapture()
{
    for (auto &observer : this->Observers) observer.first->RemoveObserver(observer.second);
}

void IsiXVTKErrorCapture::Report(vtkObject *object, const char *message)
{
    // VTK's output window would have printed it; the log keeps it.
    NSLog(@"---- VTK adapter: %s reported: %s", this->Operation ?: "", message ?: "");
    if (!this->First) this->First = IsiXVTKErrorFromLibrary(message, object ? object->GetClassName() : "", this->Operation);
}
