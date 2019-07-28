#!/bin/bash -e

./scripts/ninja.js build
BS_PLAYGROUND=../../frontend/engine_bs node ./scripts/repl.js

