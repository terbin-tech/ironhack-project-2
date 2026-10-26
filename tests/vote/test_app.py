from app import app


def test_vote_page_offers_both_options():
    # GET needs no Redis: the app connects only when a vote is posted
    client = app.test_client()
    for path in ("/", "/vote"):
        response = client.get(path)
        assert response.status_code == 200
        page = response.get_data(as_text=True)
        assert 'value="a">Cats</button>' in page
        assert 'value="b">Dogs</button>' in page
