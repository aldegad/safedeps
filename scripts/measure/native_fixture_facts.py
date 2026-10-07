"""Independent filesystem observations for native measurement fixtures.

Only the serialized clock format is shared with the record contract. All
values come from Python stat/lstat, never a hook library or core query.
"""
import os
from pathlib import Path
import sys
import time


def file_clock(path, field='c', follow=False):
    try:
        info = os.stat(path) if follow else os.lstat(path)
    except OSError:
        if follow and sys.platform == 'darwin':
            try:
                info = os.lstat(path)
            except OSError:
                return ''
        else:
            return ''
    ns = info.st_ctime_ns if field == 'c' else info.st_mtime_ns
    seconds, fraction = divmod(ns, 10**9)
    if sys.platform == 'darwin':
        return f'{seconds}.{fraction:09d}'
    local = time.localtime(seconds)
    return time.strftime('%Y-%m-%d %H:%M:%S', local) + f'.{fraction:09d} ' + time.strftime('%z', local)


def tree_inode(path):
    try:
        own = str(os.lstat(path).st_ino)
    except OSError:
        return ''
    target = str(os.stat(path).st_ino) if Path(path).exists() else ''
    return own + '|' + target


def tree_clock(path):
    own = file_clock(path)
    return own + '|' + (file_clock(path, follow=True) if Path(path).exists() else '') if own else ''


def tree_facts(project):
    names = ('package-lock.json', 'node_modules/.package-lock.json', 'node_modules')
    return ({name: tree_inode(project / name) for name in names},
            {name: tree_clock(project / name) for name in names})
