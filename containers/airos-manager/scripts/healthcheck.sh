#!/bin/bash
wget -qO- http://localhost:8080/health > /dev/null 2>&1 || exit 1
