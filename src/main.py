from fabric import SerialGroup
import os
import click
import asyncio

@click.group()
def cli():
    """Main command group"""
    pass

def get_hosts_from_env():
    hosts_str = os.getenv('EC2_HOSTS', '')
    if not hosts_str:
        raise ValueError("EC2_HOSTS environment variable is not set")
    return hosts_str.split(',')

def connect_hosts():
    host_urls = get_hosts_from_env()
    if not host_urls or len(host_urls) == 0:
        raise ValueError("No hosts found in environment variable EC2_HOSTS")
    pem_file = os.getenv('EC2_PEM_FILE', '')
    if not os.path.exists(pem_file):
        raise ValueError("No pem file is set in environment")
    
    hosts = SerialGroup(*host_urls, connect_kwargs={"key_filename": pem_file})
    hosts.run('uname -a')
    return hosts

class HostAgent:
    def __init__(self, hosts=None):
        self.hosts = hosts
        if not self.hosts:
            self.hosts = connect_hosts()
    
    def __enter__(self):
        # Return self to allow using the instance in the with block
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        # Clean up resources when exiting the context
        self.close()
        
    def update_files(self, files, destination):
        for host in self.hosts:
            for file in files:
                host.put(file, destination)

    async def update_files_async(self, files, destination):
        async def put_on_host(host, file, destination):
            return await asyncio.to_thread(host.put, file, destination)

        tasks = []
        for host in self.hosts:
            for file in files:
                tasks.append(put_on_host(host, file, destination))
                
        results = await asyncio.gather(*tasks)
        return results

    def run_command(self, command):
        for host in self.hosts:
            host.run(command)

    async def run_command_async(self, command):
        async def run_on_host(host, cmd):
            return await asyncio.to_thread(host.run, command)
        
        tasks = [run_on_host(host, command) for host in self.hosts]
        results = await asyncio.gather(*tasks)
        return results       

            
    def close(self):
        # Clean up connections
        if self.hosts:
            for host in self.hosts:
                try:
                    host.close()
                except Exception as e:
                    print(f"Error closing connection: {e}")
        self.hosts = None

@cli.command()
@click.option('--file', '-f', multiple=True, help='Files to upload')
@click.option('--des', '-d', help='Destination folder')
@click.option('--is-async', is_flag=True, default=False, help='Run command asynchronously')
def upload(file, des, is_async):
    with HostAgent() as agent:
        if is_async:
            asyncio.run(agent.update_files_async(file, des))
            return
        agent.update_files(file, des)

@cli.command()
@click.option('--command', '-c', multiple=True, help='Command to run')
@click.option('--is-async', is_flag=True, default=False, help='Run command asynchronously')
def run(command, is_async):
    with HostAgent() as agent:
        cmd = '; '.join(command)
        if is_async:
            asyncio.run(agent.run_command_async(cmd))
            return
        else:
            agent.run_command(cmd)

if __name__ == '__main__':
    cli()