#!/bin/bash -e

./ninja.js build
BS_PLAYGROUND=../../sketch-sh/client/public ./repl.js
