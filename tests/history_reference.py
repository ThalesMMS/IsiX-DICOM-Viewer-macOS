"""Which revision of this history holds a source that has since changed or gone?

Some checks compare the code under test with a reference that has left the
tree: the original OpenGL renderer, the Objective-C CPR generator, a build
script before a fix. A fixed commit hash names that reference in one history
only. This tree lives in more than one, and a history that is squashed or
rewritten no longer has the commit, so the check broke rather than tested.

These find the reference by what changed instead: the parent of the commit
that removed a file, or that removed or introduced a piece of text in it.
They answer None when the history does not reach that commit (a shallow
clone), so the check can skip.
"""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _git(*args):
    return subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, text=True).stdout.strip()


def _parent(commit):
    return _git('rev-parse', '-q', '--verify', commit + '^') or None if commit else None


def before_removal(path):
    """The last revision that has `path`."""
    return _parent(_git('log', '--diff-filter=D', '--format=%H', '-1', '--', path))


def before_text_removed(path, text):
    """The last revision whose `path` has `text`: the parent of the newest commit that changed how often it occurs."""
    return _parent(_git('log', '--format=%H', '-1', '-S', text, '--', path))


def before_text_added(path, text):
    """The last revision whose `path` lacks `text`: the parent of the oldest commit that changed how often it occurs."""
    commits = _git('log', '--reverse', '--format=%H', '-S', text, '--', path).split()
    return _parent(commits[0]) if commits else None


def show(revision, path):
    """The bytes of `path` at `revision`."""
    return subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{revision}:{path}'])
