# Shared component files

This small component holds headers shared by more than one native target. The
font tables are used by both the system app-switcher and the NetSurf SDL/OSK
shim, so they live here instead of being hidden in an ignored build workspace.
