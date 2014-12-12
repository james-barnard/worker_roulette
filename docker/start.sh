#!/bin/bash

sudo sysctl -p
cd conman && nohup bundle exec bin/conman --runtime faceplate&
cd faceplate_proxy && nohup bundle exec bin/faceplate_proxy&
