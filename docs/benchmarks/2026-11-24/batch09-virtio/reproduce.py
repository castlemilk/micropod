"""Run the MQ boot control-path branches from a hash-verified Linux 7.3.5 driver."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

EXPECTED = 'd5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace'
here = Path(__file__).resolve().parent
driver = Path(sys.argv[1]).read_bytes()
assert hashlib.sha256(driver).hexdigest() == EXPECTED
source = driver.decode()

def function(signature):
    pos = source.index(signature)
    return source[pos:source.index('\n}', pos)+2]

def boot_lines(start, end):
    boot = source[source.index('/* Enable multiqueue by default */'):]
    pos = boot.index(start)
    return boot[pos:boot.index(end, pos)+len(end)]

fragments = {
    'SET_QUEUES': function('static int virtnet_set_queues('),
    'GET_CHANNELS': function('static void virtnet_get_channels('),
    'INIT': boot_lines('if (num_online_cpus()', 'vi->max_queue_pairs = max_queue_pairs;'),
    'COUNTS': boot_lines('netif_set_real_num_tx_queues(dev, vi->curr_queue_pairs);',
                         'netif_set_real_num_rx_queues(dev, vi->curr_queue_pairs);'),
    'CONFIGURE': boot_lines('virtnet_set_queues(vi, vi->curr_queue_pairs);',
                            'virtnet_set_queues(vi, vi->curr_queue_pairs);'),
}
template = (here/'fixture.c.in').read_text()
for key, value in fragments.items():
    template = template.replace('@'+key+'@', value)
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/'mq.c'
    binary = Path(tmp)/'mq'
    c.write_text(template)
    subprocess.run(['cc','-std=c11','-O0',str(c),'-o',str(binary)],check=True)
    rows = []
    for acknowledged in (1, 0):
        row = json.loads(subprocess.check_output([str(binary),str(acknowledged)]))
        assert row['calls'] == 1 and row['requested'] == 4
        assert row['mock_device_pairs'] == (4 if acknowledged else 1)
        assert row['ethtool_combined'] == row['linux_tx'] == row['linux_rx'] == 4
        rows.append(row)
print(json.dumps(dict(driver=EXPECTED, observations=rows),sort_keys=True,indent=2))
