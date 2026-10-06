/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//  ====================================================================== 	//
//  BLAuthentication.h														//
//  																		//
//  Last Modified on Tuesday April 24 2001									//
//  Copyright 2001 Ben Lachman												//
//																			//
//	Thanks to Brian R. Hill <http://personalpages.tds.net/~brian_hill/>		//
//  ====================================================================== 	//

// BLAuthentication is implemented in Swift. The C function the
// former file exported stays here, with the same name and signature.

#import "BLAuthentication.h"
#import <Security/AuthorizationTags.h>
#include <sys/stat.h>

OSStatus AuthorizationExecuteWithPrivilegesStdErrAndPid (
                                                         AuthorizationRef authorization, 
                                                         const char *pathToTool, 
                                                         AuthorizationFlags options, 
                                                         char * const *arguments, 
                                                         FILE **communicationsPipe,
                                                         FILE **errPipe,
                                                         pid_t* processid
                                                         )
{
    // The user's own temporary folder: in /tmp another user could take the
    // fifo's name between mkstemps, unlink and mkfifo.
    [[NSFileManager defaultManager] changeCurrentDirectoryPath: NSTemporaryDirectory()];
    
    char stderrpath[PATH_MAX];
    strlcpy( stderrpath, [[NSTemporaryDirectory() stringByAppendingPathComponent: @"AuthorizationExecuteWithPrivilegesStdErrXXXXXXX.err"] fileSystemRepresentation], sizeof( stderrpath));
	const char* commandtemplate = "echo $$; \"$@\" 2>%s" ;
    if (communicationsPipe == errPipe) {
        commandtemplate = "echo $$; \"$@\" 2>1";
    } else if (errPipe == 0) {
        commandtemplate = "echo $$; \"$@\"";
    }
	char command[1024];
	char ** args = nil;
	OSStatus result;
	int argcount = 0;
	int i;
	int stderrfd = 0;
	FILE* commPipe = 0;
	
	/* Create temporary file for stderr */
    
    if (errPipe) {
        stderrfd = mkstemps (stderrpath, strlen(".err")); 
        
        /* create a pipe on that path */ 
        close(stderrfd); unlink(stderrpath);
        if (mkfifo(stderrpath,S_IRWXU | S_IRWXG) != 0) {
            fprintf(stderr,"Error mkfifo:%d\n",errno);
            return errAuthorizationInternal;
        }
        
        if (stderrfd < 0)
            return errAuthorizationInternal;
    }
    
	/* Create command to be executed */
    if( arguments)
        for (argcount = 0; arguments[argcount] != 0; ++argcount) {}	
	args = (char**)malloc (sizeof(char*)*(argcount + 5));
	args[0] = "-c";
	snprintf (command, sizeof (command), commandtemplate, stderrpath);
	args[1] = command;
	args[2] = "";
	args[3] = (char*)pathToTool;
	for (i = 0; i < argcount; ++i) {
		args[i+4] = arguments[i];
	}
	args[argcount+4] = 0;
    
    /* for debugging: log the executed command */
	/* printf ("Exec:\n%s", "/bin/sh"); for (i = 0; args[i] != 0; ++i) { printf (" \"%s\"", args[i]); } printf ("\n"); */
    
	/* Execute command */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	result = AuthorizationExecuteWithPrivileges(authorization, "/bin/sh",  options, args, &commPipe );
#pragma clang diagnostic pop
	if (result != noErr) {
		unlink (stderrpath);
        free( args);
		return result;
	}
	
    [NSThread sleepForTimeInterval: 0.2];
    
	/* Read the first line of stdout => it's the pid */
	{
		int stdoutfd = fileno (commPipe);
		char pidnum[1024];
		pid_t pid = 0;
		int i = 0;
		char ch = 0;
		while ((read(stdoutfd, &ch, sizeof(ch)) == 1) && (ch != '\n') && (i < sizeof(pidnum))) {
			pidnum[i++] = ch;
		}
		pidnum[i] = 0;
		if (ch != '\n') {
			// we shouldn't get there
			unlink (stderrpath);
			return errAuthorizationInternal;
		}
		sscanf(pidnum, "%d", &pid);
		if (processid) {
			*processid = pid;
		}
	}
	
	if (errPipe) {
        stderrfd = open(stderrpath, O_RDONLY, 0);
        *errPipe = fdopen(stderrfd, "r");
        /* Now it's safe to unlink the stderr file, as the opened handle will be still valid */
        unlink (stderrpath);
	} else {
		unlink(stderrpath);
	}
	if (communicationsPipe) {
		*communicationsPipe = commPipe;
	} else {
		fclose (commPipe);
	}
    
    [[NSFileManager defaultManager] removeItemAtPath: [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent: @"1"] error: nil];
    
    if( args)
        free( args);
    
	return noErr;
}
