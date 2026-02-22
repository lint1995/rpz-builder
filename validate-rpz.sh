#!/usr/bin/env bash
set -e

ZONE=public/rpz.zone

echo "Validating RPZ..."

named-checkzone rpz.local $ZONE

echo "Validation OK"
