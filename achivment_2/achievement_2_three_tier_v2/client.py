import argparse, requests

def main():
    parser = argparse.ArgumentParser(description="Client for 3-tier increment service")
    parser.add_argument("--url", default="http://127.0.0.1:5000/api/increment", help="Web server URL")
    parser.add_argument("--n", type=int, required=True, help="Natural number 0..N")
    args = parser.parse_args()

    r = requests.post(args.url, json={"n": args.n}, timeout=5)
    print(r.status_code, r.text)

if __name__ == "__main__":
    main()
