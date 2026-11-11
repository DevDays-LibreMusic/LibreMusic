"""Bundled utility extension entry point.

The modules are loaded lazily because solver and signed-session support pull
in optional browser dependencies.  Consumers can call ``load("solver")`` or
import ``mornye.extensions_plugins.<module>`` after the extension manager has
preloaded this package.
"""

from __future__ import annotations

from importlib import import_module

AVAILABLE_MODULES = frozenset(('spotify_metadata', 'spotify_protobuf', 'spotify_totp', 'spotfetch', 'tidal_metadata', 'solver', 'signed_session_errors', 'signed_session_mobile', 'signed_session_desktop', 'signed_session_mono', 'signed_session_status'))


def load(name: str):
    """Load one bundled utility module by its public name."""
    if name not in AVAILABLE_MODULES:
        raise ValueError(f"Unknown utilities module: {name}")
    return import_module(f"{__package__}.{name}")
