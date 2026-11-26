#!/bin/bash
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh
WOW_AUTOUPDATE=1 ; assert_ok   autoupdate_enabled
WOW_AUTOUPDATE=0 ; assert_fail autoupdate_enabled
unset WOW_AUTOUPDATE ; assert_ok autoupdate_enabled   # default ON
finish
