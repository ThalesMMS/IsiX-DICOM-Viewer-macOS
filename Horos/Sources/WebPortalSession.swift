/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// One visitor of the web portal: the session id carried by the OSID cookie,
/// the values stored for it (user, last activity, DICOM port), the Weasis
/// tokens and the login challenge.
///
/// Implemented in Swift since #718: the Objective-C name, the selectors and
/// <Horos/WebPortalSession.h> are those of the former class. The Session*Key
/// constants are defined in WebPortalSession+CAPI.m.
///
/// The dictionary is guarded by the same NSLock, around the same sections;
/// -newChallenge and -deleteChallenge did not take it and still do not.
@objc(WebPortalSession)
public final class WebPortalSession: NSObject {
    /// nil only after -init, as the former class's instance variables were.
    private let sidValue: String?
    private let dictValue: NSMutableDictionary?
    private let dictLock: NSLock?

    @objc(initWithId:)
    public init(id isid: String!) {
        sidValue = isid
        dictLock = NSLock()
        dictValue = NSMutableDictionary(capacity: 8)
        super.init()
    }

    /// -init, which NSObject gave the former class: no id, no dictionary and
    /// no lock, so every message it sends to them is a message to nil.
    public override init() {
        sidValue = nil
        dictValue = nil
        dictLock = nil
        super.init()
    }

    @objc public var sid: String! {
        return sidValue
    }

    @objc public var dict: NSMutableDictionary! {
        return dictValue
    }

    @objc(setObject:forKey:)
    public func setObject(_ o: Any!, forKey k: String!) {
        dictLock?.lock()
        if let o = o {
            // -setObject:forKey: raised NSInvalidArgumentException on a nil key.
            dictValue?.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: o, with: k)
        } else {
            dictValue?.perform(#selector(NSMutableDictionary.removeObject(forKey:)), with: k)
        }
        dictLock?.unlock()
    }

    @objc(objectForKey:)
    public func object(forKey k: String!) -> Any! {
        dictLock?.lock()
        // -objectForKey:nil answers nil.
        let value = k.flatMap { dictValue?.object(forKey: $0) }
        dictLock?.unlock()
        return value
    }

    /// Key-value coding reads the session's dictionary, not its properties:
    /// the templates' Session.Username is -objectForKey:@"Username".
    public override func value(forKey key: String) -> Any? {
        return object(forKey: key)
    }

    @objc public func tokensDictionary() -> NSMutableDictionary! {
        dictLock?.lock()
        var tdict = dictValue?.object(forKey: SessionTokensDictKey) as? NSMutableDictionary
        if tdict == nil {
            // Created even without a dictionary, as the former argument
            // expression was evaluated for a message to nil.
            let created = NSMutableDictionary()
            dictValue?.setObject(created, forKey: SessionTokensDictKey as NSString)
            tdict = created
        }
        dictLock?.unlock()
        return tdict
    }

    @objc public func createToken() -> String! {
        let tokensDictionary = self.tokensDictionary()
        dictLock?.lock()

        // A token authorises a Weasis launch on this session's behalf. It used to be
        // the MD5 of the instant it was created, so guessing it meant guessing when it
        // was made rather than searching the 128 bits its length suggests. The loop
        // stays as the invariant it always was - two live tokens are never equal - and
        // with random bytes it ends on the first pass.
        var token: String
        repeat {
            token = WebPortalIdentifier.unguessable()
        } while tokensDictionary?.object(forKey: token) != nil

        tokensDictionary?.setObject(Date(), forKey: token as NSString)

        dictLock?.unlock()
        return token
    }

    @objc(containsToken:)
    public func containsToken(_ token: String!) -> Bool {
        let tokensDictionary = self.tokensDictionary()
        dictLock?.lock()

        let date = token.flatMap { tokensDictionary?.object(forKey: $0) } as? NSDate
        var ok = false
        if let date = date {
            if date.timeIntervalSinceNow > -30 * 60 { // Token are valid for 30 min
                ok = true
            } else {
                tokensDictionary?.removeObject(forKey: token!)
            }
        }

        dictLock?.unlock()
        return ok
    }

    @objc(consumeToken:)
    public func consumeToken(_ token: String!) -> Bool {
        let tokensDictionary = self.tokensDictionary()
        dictLock?.lock()

        let date = token.flatMap { tokensDictionary?.object(forKey: $0) } as? NSDate
        var ok = false
        if let date = date {
            if date.timeIntervalSinceNow > -30 * 60 { // Token are valid for 30 min
                ok = true
            }

            tokensDictionary?.removeObject(forKey: token!)
        }

        dictLock?.unlock()
        return ok
    }

    @objc public func newChallenge() -> String! {
        // Built the same way as the token was, and replaced for the same reason.
        let challenge = WebPortalIdentifier.unguessable()
        dictValue?.setObject(challenge, forKey: SessionChallengeKey as NSString)
        return challenge
    }

    @objc public func challenge() -> String! {
        return object(forKey: SessionChallengeKey) as? String
    }

    @objc public func deleteChallenge() {
        dictValue?.removeObject(forKey: SessionChallengeKey)
    }
}
