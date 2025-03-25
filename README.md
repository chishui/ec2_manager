This simple script intends to help you to manage your clusters without needing to ssh to every one of them.

# Install
```bash
$ pip install -r requirements.txt
```

# Run
Set host urls through environment
```bash
$ export EC2_HOSTS="{{username1}}@host1,{{username2}}@host2"
```
Set pem file
```bash
$ export EC2_PEM_FILE="{{path of your pem file}}"
```
Upload file to remote hosts
```bash
$ python src/main.py upload --file={{filepath}} --des={{destination folder}}
```
Run command no remote hosts
```bash
$ python src/main.py run --command="echo 'hello world'"
```