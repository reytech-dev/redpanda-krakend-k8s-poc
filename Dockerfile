FROM devopsfaith/krakend
COPY krakend.json /etc/krakend/krakend.json
COPY krakend /usr/bin/krakend